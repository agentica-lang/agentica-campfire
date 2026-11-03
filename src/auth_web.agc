## The web side of first run, sign in and sign out: the session cookie, the CSRF check, the filter that asks for a
## signed-in person, and the routes of the forms. A page is public only if `PUBLIC_PATHS` names it, so a route that a
## later change adds needs a sign-in without anyone remembering to ask for it.

import Bond from "pkg/bond/bond"
import Auth from "auth"
import Database from "database"
import Routes from "routes"
import Slots from "slots"
import Views from "views"
import {Config} from "config"

# The cookie of the session, and the name that browsers only take from the host itself (`__Host-`, which also needs
# `Secure`, no domain and the path `/`).
COOKIE_NAME = "_campfire_session"
SECURE_COOKIE_NAME = "__Host-session"
THIRTY_DAYS = 2_592_000
TOKEN_KEY = "token"

PUBLIC_PATHS = Set.new([Routes.HEALTH, Routes.FIRST_RUN, Routes.SIGN_IN, Routes.SESSION])
BAD_LOGIN = "Wrong email or password"
BUSY = "The server is busy, try again in a moment"

# How many password hashes may run at once: 64 MiB and about a second of a scheduler each. The two routes that hash
# are open to anyone, so a burst past this is answered 503 with `Retry-After` at once instead of queueing.
MAX_HASHES = 2
RETRY_AFTER_SECONDS = "1"

## Adds to `app` the cookie sessions, the check against requests from other sites, the sign-in filter and the routes
## of the first run, the sign-in page and the sign-out. The filters run in this order, and `Bond.csrf` goes first so
## that a forged request is refused before any work. A missing `Sec-Fetch-Site` and `Origin` (a tool, not a browser)
## passes, which is what the specs and `curl` send.
export def add(app: Bond.App, config: Config) -> Bond.App
  # Per-IP limit: upstream allows 10 sign-ins per 3 minutes per address. It goes here, as a filter on `Routes.SESSION`
  # with an ATS counter, once `Bond.Conn` has the address of the client (agentica-lang/bond#46). Until then `slots`
  # bounds the hashing for everyone together, so a stranger can slow sign-in down but not take the server down.
  slots = Slots.new()
  return (
    app
    |> Bond.csrf()
    |> Bond.sessions(session_options(config))
    |> Bond.before() do |conn| require_sign_in(conn, config) end
    |> Bond.get(Routes.FIRST_RUN) do |conn| show_first_run(conn, config) end
    |> Bond.post(Routes.FIRST_RUN) do |conn| create_first_run(conn, config, slots) end
    |> Bond.get(Routes.SIGN_IN) do |conn| show_sign_in(conn, config) end
    |> Bond.post(Routes.SESSION) do |conn| create_session(conn, config, slots) end
    |> Bond.post(Routes.SIGN_OUT) do |conn| destroy_session(conn, config) end
  )
end

## The person of the request, or `none` for a visitor with no session, a session that was ended, or a user that was
## deactivated.
export def current_user(conn: Bond.Conn, config: Config) -> Result[Optional[Auth.User]]
  token = Bond.get_session(conn, TOKEN_KEY)
  if not token.ok?
    return ok(none)
  end

  return Database.with_connection(config.database_url) do |db| Auth.user_for(db, token.unwrap!) end
end

def session_options(config: Config) -> Bond.SessionOptions
  if config.secure_cookies
    return Bond.SessionOptions(
      secret: config.session_secret,
      name: SECURE_COOKIE_NAME,
      max_age: THIRTY_DAYS,
      secure: true,
    )
  end

  return Bond.SessionOptions(secret: config.session_secret, name: COOKIE_NAME, max_age: THIRTY_DAYS)
end

# A visitor goes to the first run while there is no account, and to the sign-in page after that.
def require_sign_in(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  if PUBLIC_PATHS.include?(conn.path)
    return ok(conn)
  end

  user = try current_user(conn, config)
  case user
    some(_) -> return ok(conn)
    none -> return ok(Bond.redirect(conn, try entry_path(config)))
  end
end

def entry_path(config: Config) -> Result[String]
  open = try first_run_open?(config)
  if open
    return ok(Routes.FIRST_RUN)
  end

  return ok(Routes.SIGN_IN)
end

def first_run_open?(config: Config) -> Result[Bool]
  return Database.with_connection(config.database_url) do |db| Auth.first_run?(db) end
end

def show_first_run(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  open = try first_run_open?(config)
  if not open
    return ok(Bond.redirect(conn, Routes.HOME))
  end

  return ok(Bond.html(conn, 200, Views.first_run("", "", "")))
end

def create_first_run(conn: Bond.Conn, config: Config, slots: ATS[String, Int]) -> Result[Bond.Conn]
  name = try Bond.form(conn, "name")
  email = try Bond.form(conn, "email")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  # A closed app answers every form with a redirect and no hashing, so it never has to say 503: look before taking a
  # slot. `Auth.first_run` looks again once it has the connection, and inside the transaction.
  open = try first_run_open?(config)
  if not open
    return ok(Bond.redirect(conn, Routes.HOME))
  end

  if not Slots.take?(slots, MAX_HASHES)
    return ok(busy(conn))
  end

  made = Database.with_connection(config.database_url) do |db| Auth.first_run(db, name, email, password, agent) end
  Slots.release(slots)
  outcome = try made
  case outcome
    Auth.FirstRun.Created(token) -> return ok(signed_in(conn, token))
    Auth.FirstRun.Closed -> return ok(Bond.redirect(conn, Routes.HOME))
    Auth.FirstRun.Invalid(message) -> return ok(Bond.html(conn, 422, Views.first_run(name, email, message)))
  end
end

def show_sign_in(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  open = try first_run_open?(config)
  if open
    return ok(Bond.redirect(conn, Routes.FIRST_RUN))
  end

  user = try current_user(conn, config)
  case user
    some(_) -> return ok(Bond.redirect(conn, Routes.HOME))
    none -> return ok(Bond.html(conn, 200, Views.sign_in("", "")))
  end
end

def create_session(conn: Bond.Conn, config: Config, slots: ATS[String, Int]) -> Result[Bond.Conn]
  email = try Bond.form(conn, "email")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  if not Slots.take?(slots, MAX_HASHES)
    return ok(busy(conn))
  end

  checked = Database.with_connection(config.database_url) do |db| Auth.sign_in(db, email, password, agent) end
  Slots.release(slots)
  token = try checked
  case token
    some(value) -> return ok(signed_in(conn, value))
    none -> return ok(Bond.html(conn, 422, Views.sign_in(email, BAD_LOGIN)))
  end
end

def destroy_session(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  token = Bond.get_session(conn, TOKEN_KEY)
  cleared = Bond.clear_session(conn)
  if not token.ok?
    return ok(Bond.redirect(cleared, Routes.SIGN_IN))
  end

  deleted = Database.with_connection(config.database_url) do |db| Auth.sign_out(db, token.unwrap!) end
  if not deleted.ok?
    # The person asked to sign out, so the browser forgets the cookie even though the row stays (it is the one that
    # the failure is about). An `error` here would be a 500 that keeps the cookie, so this is the 500 by hand.
    IO.warn("campfire: sign-out failed: #{deleted.message}")
    return ok(Bond.text(cleared, 500, "Internal Server Error"))
  end

  return ok(Bond.redirect(cleared, Routes.SIGN_IN))
end

# The session starts empty, so nothing of an earlier one (a fixed cookie that the visitor had) is kept.
def signed_in(conn: Bond.Conn, token: String) -> Bond.Conn
  fresh = Bond.set_session(Bond.clear_session(conn), TOKEN_KEY, token)
  return Bond.redirect(fresh, Routes.HOME)
end

# 503 for a burst of requests that hash, and when to ask again. Nothing of the form is shown again.
def busy(conn: Bond.Conn) -> Bond.Conn
  return Bond.header(Bond.html(conn, 503, Views.busy(BUSY)), "retry-after", RETRY_AFTER_SECONDS)
end

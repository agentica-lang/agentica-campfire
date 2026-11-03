## The web side of first run, sign in and sign out: the session cookie, the CSRF check, the filter that asks for a
## signed-in person, and the routes of the forms. A page is public only if `PUBLIC_PATHS` names it, so a route that a
## later change adds needs a sign-in without anyone remembering to ask for it.

import Bond from "pkg/bond/bond"
import Auth from "auth"
import Database from "database"
import Views from "views"
import {Config} from "config"

# The cookie of the session, and the name that browsers only take from the host itself (`__Host-`, which also needs
# `Secure`, no domain and the path `/`).
COOKIE_NAME = "_campfire_session"
SECURE_COOKIE_NAME = "__Host-session"
THIRTY_DAYS = 2_592_000
TOKEN_KEY = "token"

PUBLIC_PATHS = Set.new(["/health", "/first_run", "/session/new", "/session"])
FIRST_RUN_PATH = "/first_run"
SIGN_IN_PATH = "/session/new"
BAD_LOGIN = "Wrong email or password"

## Adds to `app` the cookie sessions, the check against requests from other sites, the sign-in filter and the routes
## of the first run, the sign-in page and the sign-out. The filters run in this order, and `Bond.csrf` goes first so
## that a forged request is refused before any work. A missing `Sec-Fetch-Site` and `Origin` (a tool, not a browser)
## passes, which is what the specs and `curl` send.
export def add(app: Bond.App, config: Config) -> Bond.App
  return (
    app
    |> Bond.csrf()
    |> Bond.sessions(session_options(config))
    |> Bond.before() do |conn| require_sign_in(conn, config) end
    |> Bond.get(FIRST_RUN_PATH) do |conn| show_first_run(conn, config) end
    |> Bond.post(FIRST_RUN_PATH) do |conn| create_first_run(conn, config) end
    |> Bond.get(SIGN_IN_PATH) do |conn| show_sign_in(conn, config) end
    |> Bond.post("/session") do |conn| create_session(conn, config) end
    |> Bond.post("/sign_out") do |conn| destroy_session(conn, config) end
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
    return ok(FIRST_RUN_PATH)
  end

  return ok(SIGN_IN_PATH)
end

def first_run_open?(config: Config) -> Result[Bool]
  return Database.with_connection(config.database_url) do |db| Auth.first_run?(db) end
end

def show_first_run(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  open = try first_run_open?(config)
  if not open
    return ok(Bond.redirect(conn, "/"))
  end

  return ok(Bond.html(conn, 200, Views.first_run("", "", "")))
end

def create_first_run(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  name = try Bond.form(conn, "name")
  email = try Bond.form(conn, "email")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  outcome = try Database.with_connection(config.database_url) do |db|
    Auth.first_run(db, name, email, password, agent)
  end

  case outcome
    Auth.FirstRun.Created(token) -> return ok(signed_in(conn, token))
    Auth.FirstRun.Closed -> return ok(Bond.redirect(conn, "/"))
    Auth.FirstRun.Invalid(message) -> return ok(Bond.html(conn, 422, Views.first_run(name, email, message)))
  end
end

def show_sign_in(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  open = try first_run_open?(config)
  if open
    return ok(Bond.redirect(conn, FIRST_RUN_PATH))
  end

  user = try current_user(conn, config)
  case user
    some(_) -> return ok(Bond.redirect(conn, "/"))
    none -> return ok(Bond.html(conn, 200, Views.sign_in("", "")))
  end
end

def create_session(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  email = try Bond.form(conn, "email")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  token = try Database.with_connection(config.database_url) do |db| Auth.sign_in(db, email, password, agent) end
  case token
    some(value) -> return ok(signed_in(conn, value))
    none -> return ok(Bond.html(conn, 422, Views.sign_in(email, BAD_LOGIN)))
  end
end

def destroy_session(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  token = Bond.get_session(conn, TOKEN_KEY)
  if token.ok?
    try Database.with_connection(config.database_url) do |db| Auth.sign_out(db, token.unwrap!) end
  end

  return ok(Bond.redirect(Bond.clear_session(conn), SIGN_IN_PATH))
end

# The session starts empty, so nothing of an earlier one (a fixed cookie that the visitor had) is kept.
def signed_in(conn: Bond.Conn, token: String) -> Bond.Conn
  fresh = Bond.set_session(Bond.clear_session(conn), TOKEN_KEY, token)
  return Bond.redirect(fresh, "/")
end

## The web side of first run, the join link, sign in, sign out and password reset: the session cookie, the CSRF check,
## the filter that asks for a signed-in person, and the routes of the forms. A page is public only if `PUBLIC_PATHS` names
## it (or it is the join page, see `public?`), so a route that a later change adds needs a sign-in without anyone
## remembering to ask for it.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Accounts from "../campfire/accounts"
import Auth from "../campfire/auth"
import Database from "../campfire/repo/database"
import Mailer from "../campfire/mail/mailer"
import Routes from "routes"
import Slots from "../campfire/slots"
import Smtp from "../campfire/mail/smtp"
import Views from "views"
import {Config} from "../campfire/config"

# The cookie of the session, and the name that browsers only take from the host itself (`__Host-`, which also needs
# `Secure`, no domain and the path `/`).
COOKIE_NAME = "_campfire_session"
SECURE_COOKIE_NAME = "__Host-session"
THIRTY_DAYS = 2_592_000
TOKEN_KEY = "token"

PUBLIC_PATHS = Set.new([
  Routes.HEALTH,
  Routes.FIRST_RUN,
  Routes.SIGN_IN,
  Routes.SESSION,
  Routes.PASSWORD_RESET_NEW,
  Routes.PASSWORD_RESET,
  Routes.PASSWORD_RESET_EDIT,
  Routes.PASSWORD_RESET_UPDATE,
])

# `/join/CODE` (and nothing longer) is the join page: its code is the secret that lets a stranger in, so it cannot be a
# fixed path of `PUBLIC_PATHS`. A path with more segments, or none, is not public, and a wrong code answers 404 inside
# the handler without telling anything else.
JOIN_SEGMENTS = 3

BAD_LOGIN = "Wrong email or password"
BUSY = "The server is busy, try again in a moment"

# How many password hashes may run at once: 64 MiB and about a second of a scheduler each. The two routes that hash
# are open to anyone, so a burst past this is answered 503 with `Retry-After` at once instead of queueing.
MAX_HASHES = 2
RETRY_AFTER_SECONDS = "1"

RESET_SUBJECT = "Reset your Campfire password"

## Adds to `app` the cookie sessions, the check against requests from other sites, the sign-in filter and the routes
## of the first run, the sign-in page, the sign-out and the password reset (which is only there while the `mailer` can
## send email). The filters run in this order, and `Bond.csrf` goes first so that a forged request is refused before
## any work. A missing `Sec-Fetch-Site` and `Origin` (a tool, not a browser) passes, which is what the specs and `curl`
## send.
export def add(app: Bond.App, config: Config, mailer: Mailer.Mailer) -> Bond.App
  # Per-IP limit: upstream allows 10 sign-ins per 3 minutes per address. It goes here, as a filter on `Routes.SESSION`
  # with an ATS counter, once the Bond pin has `Conn.remote_addr` (agentica-lang/agentica-campfire#9). Until then `slots`
  # bounds the hashing for everyone together, so a stranger can slow sign-in down but not take the server down.
  slots = Slots.new()
  return (
    app
    |> Bond.csrf()
    |> Bond.sessions(session_options(config))
    |> Bond.before() do |conn| require_sign_in(conn, config) end
    |> Bond.get(Routes.FIRST_RUN) do |conn| show_first_run(conn, config) end
    |> Bond.post(Routes.FIRST_RUN) do |conn| create_first_run(conn, config, slots) end
    |> Bond.get(Routes.JOIN) do |conn| show_join(conn, config) end
    |> Bond.post(Routes.JOIN) do |conn| create_join(conn, config, slots) end
    |> Bond.get(Routes.SIGN_IN) do |conn| show_sign_in(conn, config, mailer) end
    |> Bond.post(Routes.SESSION) do |conn| create_session(conn, config, slots, mailer) end
    |> Bond.post(Routes.SIGN_OUT) do |conn| destroy_session(conn, config) end
    |> Bond.get(Routes.PASSWORD_RESET_NEW) do |conn| show_forgot_password(conn, mailer) end
    |> Bond.post(Routes.PASSWORD_RESET) do |conn| create_password_reset(conn, config, mailer) end
    |> Bond.get(Routes.PASSWORD_RESET_EDIT) do |conn| show_reset_password(conn, config) end
    |> Bond.post(Routes.PASSWORD_RESET_UPDATE) do |conn| update_password(conn, config, slots) end
  )
end

## The person of the request, or `none` for a visitor with no session, a session that was ended, or a user that was
## deactivated.
export def current_user(conn: Bond.Conn, config: Config) -> Result[Optional[Auth.User]]
  return Database.with_connection(config.database_url) do |db| current_user_in(conn, db) end
end

## `current_user` on a connection that the handler has open already, so that a request that reads more than the
## person needs only one.
export def current_user_in(conn: Bond.Conn, db: Db.Connection) -> Result[Optional[Auth.User]]
  token = Bond.get_session(conn, TOKEN_KEY)
  if not token.ok?
    return ok(none)
  end

  return Auth.user_for(db, token.unwrap!)
end

## A page that holds a token or a join code is kept out of caches and out of the `Referer` of the links on it.
export def private_page(conn: Bond.Conn) -> Bond.Conn
  return Bond.header(Bond.header(conn, "cache-control", "no-store"), "referrer-policy", "no-referrer")
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
  if public?(conn.path)
    return ok(conn)
  end

  user = try current_user(conn, config)
  case user
    some(_) -> return ok(conn)
    none -> return ok(Bond.redirect(conn, try entry_path(config)))
  end
end

def public?(path: String) -> Bool
  if PUBLIC_PATHS.include?(path)
    return true
  end

  # "/join/CODE" splits into "", "join" and the code.
  parts = path.split("/")
  return parts.size == JOIN_SEGMENTS and parts[0].empty? and parts[1] == "join" and not parts[2].empty?
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

def show_join(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  code = Bond.param(conn, "code").unwrap_or("")
  valid = try join_code_valid?(config, code)
  if not valid
    return ok(not_found(conn))
  end

  return ok(private_page(Bond.html(conn, 200, Views.join(code, "", "", ""))))
end

# The code is looked at first and the form after it, so a wrong code is the same 404 whatever is posted. The hashing
# slot is taken only for a code and a form that work, and the code is looked at again in the transaction
# of `Auth.join`.
def create_join(conn: Bond.Conn, config: Config, slots: ATS[String, Int]) -> Result[Bond.Conn]
  code = Bond.param(conn, "code").unwrap_or("")
  valid = try join_code_valid?(config, code)
  if not valid
    return ok(not_found(conn))
  end

  name = try Bond.form(conn, "name")
  email = try Bond.form(conn, "email")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  # A form that cannot work (a bad value, an email that has an account) is answered before a slot is taken, since
  # it needs
  # no hashing; `Auth.join` looks again, and the transaction once more.
  problem = try join_problem(config, name, email, password)
  if problem != ""
    return ok(private_page(Bond.html(conn, 422, Views.join(code, name, email, problem))))
  end

  if not Slots.take?(slots, MAX_HASHES)
    return ok(retry_later(private_page(Bond.html(conn, 503, Views.join(code, name, email, BUSY)))))
  end

  joined = Database.with_connection(config.database_url) do |db| Auth.join(db, code, name, email, password, agent) end
  Slots.release(slots)
  outcome = try joined
  case outcome
    Auth.JoinOutcome.Joined(token) -> return ok(signed_in(conn, token))
    Auth.JoinOutcome.Gone -> return ok(not_found(conn))
    Auth.JoinOutcome.Invalid(message) ->
      return ok(private_page(Bond.html(conn, 422, Views.join(code, name, email, message))))
  end
end

def join_problem(config: Config, name: String, email: String, password: String) -> Result[String]
  return Database.with_connection(config.database_url) do |db| Auth.join_problem(db, name, email, password) end
end

def join_code_valid?(config: Config, code: String) -> Result[Bool]
  return Database.with_connection(config.database_url) do |db| Accounts.join_code_valid?(db, code) end
end

def not_found(conn: Bond.Conn) -> Bond.Conn
  return Bond.text(conn, 404, Routes.MISSING)
end

def show_sign_in(conn: Bond.Conn, config: Config, mailer: Mailer.Mailer) -> Result[Bond.Conn]
  open = try first_run_open?(config)
  if open
    return ok(Bond.redirect(conn, Routes.FIRST_RUN))
  end

  user = try current_user(conn, config)
  case user
    some(_) -> return ok(Bond.redirect(conn, Routes.HOME))
    none -> return ok(Bond.html(conn, 200, Views.sign_in("", "", Mailer.enabled?(mailer))))
  end
end

def create_session(
  conn: Bond.Conn,
  config: Config,
  slots: ATS[String, Int],
  mailer: Mailer.Mailer,
) -> Result[Bond.Conn]
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
    none -> return ok(Bond.html(conn, 422, Views.sign_in(email, BAD_LOGIN, Mailer.enabled?(mailer))))
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

# Without email there is nothing to send a link with, so the pages of the reset are not there (a fact about the app,
# the same for every visitor).
def show_forgot_password(conn: Bond.Conn, mailer: Mailer.Mailer) -> Result[Bond.Conn]
  if not Mailer.enabled?(mailer)
    return ok(Bond.text(conn, 404, Routes.MISSING))
  end

  return ok(Bond.html(conn, 200, Views.forgot_password()))
end

# The answer is the page of `Views.reset_requested` whatever the email is (and whatever the mailer does with the
# message), so the form does not tell who has an account. The sending is the mailer's, off this request.
def create_password_reset(conn: Bond.Conn, config: Config, mailer: Mailer.Mailer) -> Result[Bond.Conn]
  if not Mailer.enabled?(mailer)
    return ok(Bond.text(conn, 404, Routes.MISSING))
  end

  email = try Bond.form(conn, "email")
  # Requests that come together are decided inside the transaction of `Auth.request_password_reset`, which takes the
  # write lock first, so they send one email.
  made = Database.with_connection(config.database_url) do |db| Auth.request_password_reset(db, email) end
  reset = try made
  if reset.some? and not Mailer.enqueue(mailer, reset_message(config, reset.unwrap!))
    # The link was made but no email will carry it (the queue is full or the mailer has stopped): it goes, or the
    # person could not have another until it expired.
    forget_reset(config, reset.unwrap!.token)
  end

  return ok(Bond.html(conn, 200, Views.reset_requested()))
end

# Takes back a link that could not be sent. A failure only shows in the log: the page answers the same.
def forget_reset(config: Config, token: String) -> Void
  cancelled = Database.with_connection(config.database_url) do |db| Auth.cancel_password_reset(db, token) end
  if not cancelled.ok?
    IO.warn(
      "campfire: a reset link that could not be sent could not be removed either, and works for " +
      "#{Auth.RESET_MINUTES} minutes",
    )
  end
end

# The link starts with the address that the app is configured with, never with the `Host` of the request, which the
# visitor chooses: a link that went to another site would give the token to it.
def reset_message(config: Config, reset: Auth.PasswordReset) -> Smtp.Message
  link = "#{config.base_url}#{Routes.PASSWORD_RESET_EDIT}?token=#{reset.token}"
  return Smtp.Message(
    from: config.mail_from,
    to: [reset.email],
    subject: RESET_SUBJECT,
    text: Views.reset_mail(reset.name, link, Auth.RESET_MINUTES),
  )
end

# A GET changes nothing (a mail scanner opens links), so the link is used up by the post of the form, not by this page.
def show_reset_password(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  token = Bond.query(conn, "token").unwrap_or("")
  valid = try reset_token_valid?(config, token)
  if not valid
    return ok(link_gone(conn))
  end

  return ok(private_page(Bond.html(conn, 200, Views.reset_password(token, ""))))
end

def update_password(conn: Bond.Conn, config: Config, slots: ATS[String, Int]) -> Result[Bond.Conn]
  token = try Bond.form(conn, "token")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  # A link that does not work is answered before a slot is taken, since it needs no hashing.
  valid = try reset_token_valid?(config, token)
  if not valid
    return ok(link_gone(conn))
  end

  if not Slots.take?(slots, MAX_HASHES)
    return ok(busy_reset_form(conn, token))
  end

  # `Auth.reset_password` checks the link again inside its write transaction, so two forms for one link change the
  # password once; the second one hashes for nothing, which the slot already bounds.
  changed = Database.with_connection(config.database_url) do |db| Auth.reset_password(db, token, password, agent) end
  Slots.release(slots)
  outcome = try changed
  case outcome
    Auth.ResetOutcome.SignedIn(session) -> return ok(signed_in(conn, session))
    Auth.ResetOutcome.Gone -> return ok(link_gone(conn))
    Auth.ResetOutcome.Invalid(message) ->
      return ok(private_page(Bond.html(conn, 422, Views.reset_password(token, message))))
  end
end

def reset_token_valid?(config: Config, token: String) -> Result[Bool]
  return Database.with_connection(config.database_url) do |db| Auth.reset_token_valid?(db, token) end
end

def link_gone(conn: Bond.Conn) -> Bond.Conn
  return private_page(Bond.html(conn, 410, Views.reset_link_gone()))
end

# The session starts empty, so nothing of an earlier one (a fixed cookie that the visitor had) is kept.
def signed_in(conn: Bond.Conn, token: String) -> Bond.Conn
  fresh = Bond.set_session(Bond.clear_session(conn), TOKEN_KEY, token)
  return Bond.redirect(fresh, Routes.HOME)
end

# 503 for a burst of requests that hash, and when to ask again. Nothing of the form is shown again.
def busy(conn: Bond.Conn) -> Bond.Conn
  return retry_later(Bond.html(conn, 503, Views.busy(BUSY)))
end

# The form comes back with the token, so a person does not have to ask for another link because of a burst.
def busy_reset_form(conn: Bond.Conn, token: String) -> Bond.Conn
  return retry_later(private_page(Bond.html(conn, 503, Views.reset_password(token, BUSY))))
end

def retry_later(conn: Bond.Conn) -> Bond.Conn
  return Bond.header(conn, "retry-after", RETRY_AFTER_SECONDS)
end

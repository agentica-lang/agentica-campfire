## The web side of first run, the join link, sign in, sign out and password reset: the session cookie, the CSRF check,
## the filter that asks for a signed-in person, and the routes of the forms. A page is public only if `PUBLIC_PATHS` names
## it (or it is the join page, see `public?`), so a route that a later change adds needs a sign-in without anyone
## remembering to ask for it.

import Bond from "pkg/bond/bond"
import Channels from "pkg/channels/channels"
import Db from "pkg/db/db"
import Accounts from "../campfire/accounts"
import Auth from "../campfire/auth"
import Bans from "../campfire/bans"
import Database from "../campfire/repo/database"
import Failure from "failure"
import Hangup from "hangup"
import Mailer from "../campfire/mail/mailer"
import RateLimit from "../campfire/rate_limit"
import Routes from "routes"
import Slots from "../campfire/slots"
import Smtp from "../campfire/mail/smtp"
import Views from "views"
import {Config} from "../campfire/config"

# The cookie of the session, and the name that browsers only take from the host itself (`__Host-`, which also needs
# `Secure`, no domain and the path `/`).
COOKIE_NAME = "session_token"
SECURE_COOKIE_NAME = "__Host-session_token"
TOKEN_KEY = "token"
# Where the sign-in filter keeps the person for the handler (`Bond.assign`).
USER_KEY = "user"

PUBLIC_PATHS = Set.new([
  Routes.HEALTH,
  Routes.CABLE,
  Routes.UP,
  Routes.FIRST_RUN,
  Routes.SIGN_IN,
  Routes.SESSION,
  Routes.PASSWORD_RESET_NEW,
  Routes.PASSWORD_RESET,
  Routes.PASSWORD_RESET_EDIT,
  Routes.PASSWORD_RESET_UPDATE,
])

# Everything under `/assets/` is public: the files of the assets folder, which are not secret.
ASSETS_PREFIX = "#{Routes.ASSETS}/"

# `/join/CODE` (and nothing longer) is the join page: its code is the secret that lets a stranger in, so it cannot be a
# fixed path of `PUBLIC_PATHS`. A path with more segments, or none, is not public, and a wrong code answers 404 inside
# the handler without telling anything else.
JOIN_SEGMENTS = 3

BAD_LOGIN = "Wrong email or password"
TOO_MANY = "Too many sign-in attempts, try again later"

# At most this many attempts to sign in (every post to `Routes.SESSION`, right or wrong) from one address in this time,
# as upstream Campfire has it: 10 in 3 minutes.
SIGN_IN_ATTEMPTS = 10
SIGN_IN_WINDOW_MS = 180_000

# How many password hashes may run at once: 64 MiB and about a second of a scheduler each for scrypt, and a thread of
# the compute pool for about a quarter of a second for a bcrypt digest of cost 12. The routes that hash are open to
# anyone, so a burst past this is answered 503 with `Retry-After` at once instead of queueing.
export MAX_HASHES = 2

RESET_SUBJECT = "Reset your Campfire password"

## Adds to `app` the cookie sessions, the check against requests from other sites, the sign-in filter and the routes
## of the first run, the sign-in page, the sign-out and the password reset (which is only there while the `mailer` can
## send email). The filters run in this order, and `Bond.csrf` goes first so that a forged request is refused before
## any work. A missing `Sec-Fetch-Site` and `Origin` (a tool, not a browser) passes, which is what the specs and `curl`
## send.
export def add(
  app: Bond.App,
  config: Config,
  pool: Database.Pool,
  mailer: Mailer.Mailer,
  hub: Channels.Hub,
  slots: ATS[String, Int],
) -> Bond.App
  # `slots` bounds the hashing for everyone together (the profile shares it); `attempts` bounds the sign-in posts of
  # one address.
  attempts = RateLimit.new()
  return (
    app
    |> Bond.csrf()
    |> Bond.before() do |conn| reject_banned(conn, pool) end
    |> Bond.sessions(session_options(config))
    |> Bond.before() do |conn| require_sign_in(conn, pool) end
    |> Bond.get(Routes.FIRST_RUN) do |conn| show_first_run(conn, pool) end
    |> Bond.post(Routes.FIRST_RUN) do |conn| create_first_run(conn, pool, slots) end
    |> Bond.get(Routes.JOIN) do |conn| show_join(conn, pool) end
    |> Bond.post(Routes.JOIN) do |conn| create_join(conn, pool, slots) end
    |> Bond.get(Routes.SIGN_IN) do |conn| show_sign_in(conn, pool, mailer) end
    |> Bond.post(Routes.SESSION) do |conn| create_session(conn, config, pool, slots, attempts, mailer) end
    |> Bond.post(Routes.SIGN_OUT) do |conn| destroy_session(conn, pool, hub) end
    |> Bond.get(Routes.PASSWORD_RESET_NEW) do |conn| show_forgot_password(conn, mailer) end
    |> Bond.post(Routes.PASSWORD_RESET) do |conn| create_password_reset(conn, config, pool, mailer) end
    |> Bond.get(Routes.PASSWORD_RESET_EDIT) do |conn| show_reset_password(conn, pool) end
    |> Bond.post(Routes.PASSWORD_RESET_UPDATE) do |conn| update_password(conn, pool, slots, hub) end
  )
end

## The token of the session cookie, "" when the request has none.
export def session_token(conn: Bond.Conn) -> String
  return Bond.get_session(conn, TOKEN_KEY).unwrap_or("")
end

## The person of the request, or `none` for a visitor with no session, a session that was ended, or a user that was
## deactivated.
export def current_user(conn: Bond.Conn, pool: Database.Pool) -> Result[Optional[Auth.User]]
  return Database.with_connection(pool) do |db| user_of_session(conn, db) end
end

## The person that the sign-in filter looked up and kept with `Bond.assign`, so a handler does not look them up again.
## `none` for a request that the filter did not see (a public page); a signed-in page always has one.
export def assigned_user(conn: Bond.Conn) -> Result[Optional[Auth.User]]
  if not Bond.assigned?(conn, USER_KEY)
    return ok(none)
  end

  user = try Bond.assigned(conn, USER_KEY, JSON.codec(Auth.User))
  return ok(some(user))
end

## The `_method` field of a form, lower case ("" when it has none), which is how Rails reads it
## (`Rack::MethodOverride`): a browser form cannot send `PATCH`, `PUT` or `DELETE`, so it posts and names the method.
export def form_method(conn: Bond.Conn) -> Result[String]
  methods = try Bond.form_all(conn, "_method")
  if methods.empty?
    return ok("")
  end

  return ok(methods[0].downcase)
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
      max_age: Auth.SESSION_SECONDS,
      secure: true,
    )
  end

  return Bond.SessionOptions(secret: config.session_secret, name: COOKIE_NAME, max_age: Auth.SESSION_SECONDS)
end

def user_of_session(conn: Bond.Conn, db: Db.Connection) -> Result[Optional[Auth.User]]
  token = Bond.get_session(conn, TOKEN_KEY)
  if not token.ok?
    return ok(none)
  end

  return Auth.user_for(db, token.unwrap!)
end

# A visitor goes to the first run while there is no account, and to the sign-in page after that.
# A request that changes something and comes from an address that a ban holds is refused with 429 before anything else
# is looked at (`BlockBannedRequests`): a banned person cannot sign in again from where they were, nor post. Reading
# stays open, as in Rails. The address is the peer of the connection, as for the sign-in limit.
def reject_banned(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  if conn.method == "GET" or conn.method == "HEAD"
    return ok(conn)
  end

  banned = try Database.with_connection(pool) do |db| Bans.banned?(db, conn.remote_addr) end
  if banned
    return ok(Bond.text(conn, 429, "Too Many Requests"))
  end

  return ok(conn)
end

def require_sign_in(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  if public?(conn.path)
    return ok(conn)
  end

  user = try current_user(conn, pool)
  case user
    some(person) -> return ok(Bond.assign(conn, USER_KEY, person))
    none -> return ok(Bond.redirect(conn, try entry_path(pool)))
  end
end

def public?(path: String) -> Bool
  if PUBLIC_PATHS.include?(path)
    return true
  end

  # The stylesheet and whatever else is in the assets folder: the sign-in page needs its style before anybody has
  # signed in. A path that is not a file there is a 404 (`Bond.static` refuses a way out of the folder), whoever asks.
  if path.start_with?(ASSETS_PREFIX)
    return true
  end

  # "/join/CODE" splits into "", "join" and the code.
  parts = path.split("/")
  return parts.size == JOIN_SEGMENTS and parts[0].empty? and parts[1] == "join" and not parts[2].empty?
end

def entry_path(pool: Database.Pool) -> Result[String]
  open = try first_run_open?(pool)
  if open
    return ok(Routes.FIRST_RUN)
  end

  return ok(Routes.SIGN_IN)
end

def first_run_open?(pool: Database.Pool) -> Result[Bool]
  return Database.with_connection(pool) do |db| Auth.first_run?(db) end
end

def show_first_run(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  open = try first_run_open?(pool)
  if not open
    return ok(Bond.redirect(conn, Routes.HOME))
  end

  return ok(Bond.html(conn, 200, Views.first_run("", "", "")))
end

def create_first_run(conn: Bond.Conn, pool: Database.Pool, slots: ATS[String, Int]) -> Result[Bond.Conn]
  name = try Bond.form(conn, "name")
  email = try Bond.form(conn, "email")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  # A closed app answers every form with a redirect and no hashing, so it never has to say 503: look before taking a
  # slot. `Auth.first_run` looks again once it has the connection, and inside the transaction.
  open = try first_run_open?(pool)
  if not open
    return ok(Bond.redirect(conn, Routes.HOME))
  end

  if not Slots.take?(slots, MAX_HASHES)
    return ok(busy(conn))
  end

  made = Database.with_connection(pool) do |db| Auth.first_run(db, name, email, password, agent, conn.remote_addr) end

  Slots.release(slots)
  outcome = try made
  case outcome
    Auth.FirstRun.Created(token) -> return ok(signed_in(conn, token))
    Auth.FirstRun.Closed -> return ok(Bond.redirect(conn, Routes.HOME))
    Auth.FirstRun.Invalid(message) -> return ok(Bond.html(conn, 422, Views.first_run(name, email, message)))
  end
end

def show_join(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  code = Bond.param(conn, "code").unwrap_or("")
  valid = try join_code_valid?(pool, code)
  if not valid
    return ok(not_found(conn))
  end

  return ok(private_page(Bond.html(conn, 200, Views.join(code, "", "", ""))))
end

# The code is looked at first and the form after it, so a wrong code is the same 404 whatever is posted. The hashing
# slot is taken only for a code and a form that work, and the code is looked at again in the transaction
# of `Auth.join`.
def create_join(conn: Bond.Conn, pool: Database.Pool, slots: ATS[String, Int]) -> Result[Bond.Conn]
  code = Bond.param(conn, "code").unwrap_or("")
  valid = try join_code_valid?(pool, code)
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
  problem = try join_problem(pool, name, email, password)
  if problem != ""
    return ok(private_page(Bond.html(conn, 422, Views.join(code, name, email, problem))))
  end

  if not Slots.take?(slots, MAX_HASHES)
    return ok(retry_later(private_page(Bond.html(conn, 503, Views.join(code, name, email, Failure.BUSY)))))
  end

  joined = Database.with_connection(pool) do |db|
    Auth.join(db, code, name, email, password, agent, conn.remote_addr)
  end

  Slots.release(slots)
  outcome = try joined
  case outcome
    Auth.JoinOutcome.Joined(token) -> return ok(signed_in(conn, token))
    Auth.JoinOutcome.Gone -> return ok(not_found(conn))
    Auth.JoinOutcome.Invalid(message) ->
      return ok(private_page(Bond.html(conn, 422, Views.join(code, name, email, message))))
  end
end

def join_problem(pool: Database.Pool, name: String, email: String, password: String) -> Result[String]
  return Database.with_connection(pool) do |db| Auth.join_problem(db, name, email, password) end
end

def join_code_valid?(pool: Database.Pool, code: String) -> Result[Bool]
  return Database.with_connection(pool) do |db| Accounts.join_code_valid?(db, code) end
end

def not_found(conn: Bond.Conn) -> Bond.Conn
  return Bond.text(conn, 404, Routes.MISSING)
end

def show_sign_in(conn: Bond.Conn, pool: Database.Pool, mailer: Mailer.Mailer) -> Result[Bond.Conn]
  open = try first_run_open?(pool)
  if open
    return ok(Bond.redirect(conn, Routes.FIRST_RUN))
  end

  user = try current_user(conn, pool)
  case user
    some(_) -> return ok(Bond.redirect(conn, Routes.HOME))
    none -> return ok(Bond.html(conn, 200, Views.sign_in("", "", Mailer.enabled?(mailer))))
  end
end

# The attempt is counted here, in the handler of the route, and not by a filter that matches the path: the router also
# takes `/session/` and `//session` to this handler, and a filter that missed one of those would let a person guess
# passwords without limit. It is counted first, so a refused attempt reads no form and takes no hashing slot. The
# address is the peer of the connection: behind a proxy it is the proxy's, so every visitor shares one window
# (docs/security.md).
def create_session(
  conn: Bond.Conn,
  config: Config,
  pool: Database.Pool,
  slots: ATS[String, Int],
  attempts: ATS[String, Int],
  mailer: Mailer.Mailer,
) -> Result[Bond.Conn]
  wait = RateLimit.hit(attempts, conn.remote_addr, Time.monotonic_ms(), SIGN_IN_ATTEMPTS, SIGN_IN_WINDOW_MS)
  if wait > 0
    return ok(Bond.header(Bond.html(conn, 429, Views.busy(TOO_MANY)), "retry-after", wait.to_s))
  end

  email = try Bond.form(conn, "email_address")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  if not Slots.take?(slots, MAX_HASHES)
    return ok(busy(conn))
  end

  checked = Database.with_connection(pool) do |db|
    Auth.sign_in(db, email, password, agent, conn.remote_addr, config.bcrypt_library)
  end

  Slots.release(slots)
  token = try checked
  case token
    some(value) -> return ok(signed_in(conn, value))
    none -> return ok(Bond.html(conn, 422, Views.sign_in(email, BAD_LOGIN, Mailer.enabled?(mailer))))
  end
end

# The sockets of the person are told to reconnect: the ones of their other sessions are welcomed again at once, and
# the ones of this browser are refused, since its cookie is gone (`Hangup`).
def destroy_session(conn: Bond.Conn, pool: Database.Pool, hub: Channels.Hub) -> Result[Bond.Conn]
  person = try assigned_user(conn)
  token = Bond.get_session(conn, TOKEN_KEY)
  cleared = Bond.clear_session(conn)
  if not token.ok?
    return ok(Bond.redirect(cleared, Routes.SIGN_IN))
  end

  deleted = Database.with_connection(pool) do |db| Auth.sign_out(db, token.unwrap!) end
  if not deleted.ok?
    # The person asked to sign out, so the browser forgets the cookie even though the row stays (it is the one that
    # the failure is about). An `error` here would keep the cookie, so the answer is made by hand, as the app
    # makes it for any failure (a 503 when the database was busy, else a 500).
    IO.warn("campfire: sign-out failed: #{deleted.message}")
    return ok(Failure.answer(cleared, deleted.message))
  end

  if person.some?
    Hangup.user(hub, person.unwrap!.id, true)
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
def create_password_reset(
  conn: Bond.Conn,
  config: Config,
  pool: Database.Pool,
  mailer: Mailer.Mailer,
) -> Result[Bond.Conn]
  if not Mailer.enabled?(mailer)
    return ok(Bond.text(conn, 404, Routes.MISSING))
  end

  email = try Bond.form(conn, "email")
  # Requests that come together are decided inside the transaction of `Auth.request_password_reset`, which takes the
  # write lock first, so they send one email.
  made = Database.with_connection(pool) do |db| Auth.request_password_reset(db, email) end
  reset = try made
  if reset.some? and not Mailer.enqueue(mailer, reset_message(config, reset.unwrap!))
    # The link was made but no email will carry it (the queue is full or the mailer has stopped): it goes, or the
    # person could not have another until it expired.
    forget_reset(pool, reset.unwrap!.token)
  end

  return ok(Bond.html(conn, 200, Views.reset_requested()))
end

# Takes back a link that could not be sent. A failure only shows in the log: the page answers the same.
def forget_reset(pool: Database.Pool, token: String) -> Void
  cancelled = Database.with_connection(pool) do |db| Auth.cancel_password_reset(db, token) end
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
def show_reset_password(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  token = Bond.query(conn, "token").unwrap_or("")
  valid = try reset_token_valid?(pool, token)
  if not valid
    return ok(link_gone(conn))
  end

  return ok(private_page(Bond.html(conn, 200, Views.reset_password(token, ""))))
end

def update_password(
  conn: Bond.Conn,
  pool: Database.Pool,
  slots: ATS[String, Int],
  hub: Channels.Hub,
) -> Result[Bond.Conn]
  token = try Bond.form(conn, "token")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  # A link that does not work is answered before a slot is taken, since it needs no hashing.
  valid = try reset_token_valid?(pool, token)
  if not valid
    return ok(link_gone(conn))
  end

  if not Slots.take?(slots, MAX_HASHES)
    return ok(busy_reset_form(conn, token))
  end

  # `Auth.reset_password` checks the link again inside its write transaction, so two forms for one link change the
  # password once; the second one hashes for nothing, which the slot already bounds.
  changed = Database.with_connection(pool) do |db|
    Auth.reset_password(db, token, password, agent, conn.remote_addr)
  end

  Slots.release(slots)
  outcome = try changed
  case outcome
    Auth.ResetOutcome.SignedIn(session, user_id) ->
      # The reset ended every session of the person: their sockets are told to reconnect, and are refused.
      Hangup.user(hub, user_id, true)
      return ok(signed_in(conn, session))
    Auth.ResetOutcome.Gone -> return ok(link_gone(conn))
    Auth.ResetOutcome.Invalid(message) ->
      return ok(private_page(Bond.html(conn, 422, Views.reset_password(token, message))))
  end
end

def reset_token_valid?(pool: Database.Pool, token: String) -> Result[Bool]
  return Database.with_connection(pool) do |db| Auth.reset_token_valid?(db, token) end
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
  return retry_later(Bond.html(conn, 503, Views.busy(Failure.BUSY)))
end

# The form comes back with the token, so a person does not have to ask for another link because of a burst.
def busy_reset_form(conn: Bond.Conn, token: String) -> Bond.Conn
  return retry_later(private_page(Bond.html(conn, 503, Views.reset_password(token, Failure.BUSY))))
end

def retry_later(conn: Bond.Conn) -> Bond.Conn
  return Bond.header(conn, "retry-after", Failure.RETRY_AFTER_SECONDS)
end

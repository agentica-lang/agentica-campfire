## The web side of first run, the join link, sign in, sign out and password reset: the session cookie, the CSRF check,
## the filter that asks for a signed-in person, and the routes of the forms. A page is public only if `PUBLIC_PATHS` names
## it (or it is the join page, see `public?`), so a route that a later change adds needs a sign-in without anyone
## remembering to ask for it.

import Bond from "pkg/bond/bond"
import Channels from "pkg/channels/channels"
import Db from "pkg/db/db"
import Accounts from "../campfire/accounts"
import Auth from "../campfire/auth"
import BanFlag from "ban_flag"
import Bans from "../campfire/bans"
import Blocks from "blocks"
import Database from "../campfire/repo/database"
import Failure from "failure"
import Hangup from "hangup"
import Mailer from "../campfire/mail/mailer"
import PageCache from "page_cache"
import RateLimit from "../campfire/rate_limit"
import Routes from "routes"
import Slots from "../campfire/slots"
import Smtp from "../campfire/mail/smtp"
import Views from "views"
import {Config} from "../campfire/config"

# How many password hashes may run at once: 64 MiB and about a second of a scheduler each for scrypt, and a thread of
# the compute pool for about a quarter of a second for a bcrypt digest of cost 12. The routes that hash are open to
# anyone, so a burst past this is answered 503 with `Retry-After` at once instead of queueing.
MAX_HASHES = 2

## What `person_in` found: the person, or the page that the sign-in filter sends a visitor to.
enum Found
  Person(Auth.User)
  Entry(String)
end

## Adds to `app` the cookie sessions, the check against requests from other sites, the sign-in filter and the routes
## of the first run, the sign-in page, the sign-out and the password reset (which is only there while the `mailer` can
## send email). The filters run in this order, and `Bond.csrf` goes first so that a forged request is refused before
## any work. A missing `Sec-Fetch-Site` and `Origin` (a tool, not a browser) passes, which is what the specs and `curl`
## send. The messages API of the bots is the exception to the check (`unmarked`), and a path that `bot_api?` names needs
## no session.
def add(
  app: Bond.App,
  config: Config,
  pool: Database.Pool,
  mailer: Mailer.Mailer,
  hub: Channels.Hub,
  slots: ATS[String, Int],
  bans: ATS[String, Int],
  pages: Optional[PageCache.Pages] = none,
) -> Bond.App
  # `slots` bounds the hashing for everyone together (the profile shares it); `attempts` bounds the sign-in posts of
  # one address.
  attempts = RateLimit.new()
  on_before_unmarked = Blocks.handler do |conn| ok(unmarked(conn)) end
  on_before_reject_banned = Blocks.handler do |conn| reject_banned(conn, pool, bans) end
  on_before_require_sign_in = Blocks.handler do |conn| require_sign_in(conn, pool, pages) end
  on_get_first_run = Blocks.handler do |conn| show_first_run(conn, pool) end
  on_post_first_run = Blocks.handler do |conn| create_first_run(conn, pool, slots) end
  on_get_join = Blocks.handler do |conn| show_join(conn, pool) end
  on_post_join = Blocks.handler do |conn| create_join(conn, pool, slots) end
  on_get_sign_in = Blocks.handler do |conn| show_sign_in(conn, pool, mailer) end
  on_post_session = Blocks.handler do |conn| create_session(conn, config, pool, slots, attempts, mailer) end
  on_post_sign_out = Blocks.handler do |conn| destroy_session(conn, pool, hub) end
  on_get_password_reset_new = Blocks.handler do |conn| show_forgot_password(conn, mailer) end
  on_post_password_reset = Blocks.handler do |conn| create_password_reset(conn, config, pool, mailer) end
  on_get_password_reset_edit = Blocks.handler do |conn| show_reset_password(conn, pool) end

  (
    app
    |> Bond.before(on_before_unmarked)
    |> Bond.csrf()
    |> Bond.before(on_before_reject_banned)
    |> Bond.sessions(session_options(config))
    |> Bond.before(on_before_require_sign_in)
    |> Bond.get(Routes.FIRST_RUN, on_get_first_run)
    |> Bond.post(Routes.FIRST_RUN, on_post_first_run)
    |> Bond.get(Routes.JOIN, on_get_join)
    |> Bond.post(Routes.JOIN, on_post_join)
    |> Bond.get(Routes.SIGN_IN, on_get_sign_in)
    |> Bond.post(Routes.SESSION, on_post_session)
    |> Bond.post(Routes.SIGN_OUT, on_post_sign_out)
    |> Bond.get(Routes.PASSWORD_RESET_NEW, on_get_password_reset_new)
    |> Bond.post(Routes.PASSWORD_RESET, on_post_password_reset)
    |> Bond.get(Routes.PASSWORD_RESET_EDIT, on_get_password_reset_edit)
    |> Bond.post(Routes.PASSWORD_RESET_UPDATE) do |conn| update_password(conn, pool, slots, hub) end
  )
end

## The token of the session cookie, "" when the request has none.
def session_token(conn: Bond.Conn) -> String = Bond.get_session(conn, TOKEN_KEY).unwrap_or("")

## The person of the request, or `none` for a visitor with no session, a session that was ended, or a user that was
## deactivated.
def current_user(conn: Bond.Conn, pool: Database.Pool) -> Result[Optional[Auth.User]]
  Database.with_connection(pool) do |db| user_of_session(conn, db) end
end

## True for the post of a message (`Routes.ROOM_MESSAGES`), whose handler looks the person up in the connection that it
## writes with (`person_in`), so that the post takes one connection of the pool and not two: the filter leaves the
## lookup to it for a request that has a session cookie. A path of the bots (`bot_api?`) has more segments.
def lookup_in_handler?(conn: Bond.Conn) -> Bool = message_post?(conn.method, conn.path)

## `lookup_in_handler?` for a method and a path. The path is read as the router reads it, by its non-empty segments,
## against the segments of `Routes.ROOM_MESSAGES`, where a segment that starts with ":" is any value.
def message_post?(method: String, path: String) -> Bool
  return false if method != "POST"

  wanted = Routes.ROOM_MESSAGES.split("/").select do |part| not part.empty? end
  parts = path.split("/").select do |part| not part.empty? end
  return false if parts.size != wanted.size

  for index in 0...wanted.size
    return false if not wanted[index].start_with?(":") and wanted[index] != parts[index]
  end

  true
end

## The person of a request, for a handler that has a connection `db`: when `lookup_in_handler?` left the lookup to it,
## the lookup is made in `db` (and a visitor is sent where the filter sends them: the first run while there is no
## account, else the sign-in page); otherwise it is the person that the filter kept (`assigned_user`).
def person_in(conn: Bond.Conn, db: Db.Connection) -> Result[Found]
  if not lookup_in_handler?(conn)
    kept = try assigned_user(conn)
    case kept
      some(person) -> return ok(Found.Person(person))
      none -> return ok(Found.Entry(Routes.SIGN_IN))
    end
  end

  found = try user_of_session(conn, db)
  case found
    some(person) -> ok(Found.Person(person))
    none ->
      return ok(Found.Entry(Routes.FIRST_RUN)) if try Auth.first_run?(db)

      ok(Found.Entry(Routes.SIGN_IN))
  end
end

## The person that the sign-in filter looked up and kept with `Bond.assign`, so a handler does not look them up again.
## `none` for a request that the filter did not see (a public page); a signed-in page always has one.
def assigned_user(conn: Bond.Conn) -> Result[Optional[Auth.User]]
  return ok(none) if not Bond.assigned?(conn, USER_KEY)

  user = try Bond.assigned(conn, USER_KEY, Auth.User.codec)
  ok(some(user))
end

## The `_method` field of a form, lower case ("" when it has none), which is how Rails reads it
## (`Rack::MethodOverride`): a browser form cannot send `PATCH`, `PUT` or `DELETE`, so it posts and names the method.
def form_method(conn: Bond.Conn) -> Result[String]
  methods = try Bond.form_all(conn, "_method")
  return ok("") if methods.empty?

  ok(methods[0].downcase)
end

## True for a path of the messages API of the chat bots, `/rooms/ID/KEY/messages`, `/rooms/ID/KEY/messages/ID` and the
## boosts under a message, `/rooms/ID/KEY/messages/ID/boosts` and `/rooms/ID/KEY/messages/ID/boosts/ID`.
## The key in the path is the whole login, so the sign-in filter lets it through and the handler looks the key up.
## The parts are the non-empty segments, which is how the router reads a path, so a path that is true here is a path
## of the API and not a browser path with an odd shape (`/rooms/1//messages` is the messages of room 1, and
## `/rooms/1/messages/9`, the message 9, have `messages` where the key is).
def bot_api?(path: String) -> Bool
  parts = path.split("/").select do |part| not part.empty? end
  return false if parts.size < BOT_LIST_SEGMENTS or parts.size > BOT_BOOST_SEGMENTS

  return false if parts[0] != "rooms" or parts[2] == "messages" or parts[3] != "messages"

  # The boosts have `boosts` after the message; the list and the message have nothing more to check.
  parts.size < BOT_BOOSTS_SEGMENTS or parts[5] == "boosts"
end

## A page that holds a token or a join code is kept out of caches and out of the `Referer` of the links on it. The policy
## is `same-origin`, not `no-referrer`: with `no-referrer` a browser on plain HTTP sends `Origin: null` on the forms of
## the page, which `Bond.csrf` refuses (a post to the page's own site carries its real `Origin`). A link to another site
## still gets no `Referer`.
def private_page(conn: Bond.Conn) -> Bond.Conn
  Bond.header(Bond.header(conn, "cache-control", "no-store"), "referrer-policy", "same-origin")
end

## Starts the session `token` in this browser and goes home. The session starts empty, so nothing of an earlier one (a
## fixed cookie that the visitor had) is kept.
def signed_in(conn: Bond.Conn, token: String) -> Bond.Conn
  fresh = Bond.set_session(Bond.clear_session(conn), TOKEN_KEY, token)
  Bond.redirect(fresh, Routes.HOME)
end

private

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
  Routes.WEBMANIFEST,
  Routes.SERVICE_WORKER,
  Routes.ACCOUNT_LOGO,
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
# `/session/transfers/TOKEN`: the token is the secret that signs a browser in, checked by the handler.
TRANSFER_SEGMENTS = 4
# The segments of `/rooms/ID/KEY/messages`, of `/rooms/ID/KEY/messages/ID`, and of the boosts under a message,
# `/rooms/ID/KEY/messages/ID/boosts` and `/rooms/ID/KEY/messages/ID/boosts/ID`.
BOT_LIST_SEGMENTS = 4
BOT_MESSAGE_SEGMENTS = 5
BOT_BOOSTS_SEGMENTS = 6
BOT_BOOST_SEGMENTS = 7
# The request headers that `Bond.csrf` reads.
CROSS_SITE_HEADERS = Set.new(["origin", "sec-fetch-site"])
BAD_LOGIN = "Wrong email or password"
TOO_MANY = "Too many sign-in attempts, try again later"
# At most this many attempts to sign in (every post to `Routes.SESSION`, right or wrong) from one address in this time,
# as upstream Campfire has it: 10 in 3 minutes.
SIGN_IN_ATTEMPTS = 10
SIGN_IN_WINDOW_MS = 180_000
RESET_SUBJECT = "Reset your Campfire password"

# `Bond.csrf` refuses a post that a page of another site sent, judging by `Sec-Fetch-Site` and `Origin`. The messages
# API of the bots is the one place where a page of another site may call (a dashboard that posts with a key, as Rails
# lets a request with a bot key skip the check): its key is in the path and no cookie is read, so a forged post has
# nothing to forge, and the browser routes keep the check. The two headers are left out of the request here, before the
# check.
def unmarked(conn: Bond.Conn) -> Bond.Conn
  return conn if not bot_api?(conn.path)

  conn.with(headers: conn.headers.select do |field| not CROSS_SITE_HEADERS.include?(field.name.downcase) end)
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

  Bond.SessionOptions(secret: config.session_secret, name: COOKIE_NAME, max_age: Auth.SESSION_SECONDS)
end

def user_of_session(conn: Bond.Conn, db: Db.Connection) -> Result[Optional[Auth.User]]
  token = Bond.get_session(conn, TOKEN_KEY)
  return ok(none) if not token.ok?

  found = try Auth.user_for(db, token.unwrap!)
  case found
    some(session) -> ok(some(session.user))
    none -> ok(none)
  end
end

# A visitor goes to the first run while there is no account, and to the sign-in page after that.
# A request that changes something and comes from an address that a ban holds is refused with 429 before anything else
# is looked at (`BlockBannedRequests`): a banned person cannot sign in again from where they were, nor post. Reading
# stays open, as in Rails. The address is the peer of the connection, as for the sign-in limit.
def reject_banned(conn: Bond.Conn, pool: Database.Pool, bans: ATS[String, Int]) -> Result[Bond.Conn]
  return ok(conn) if conn.method == "GET" or conn.method == "HEAD" or not BanFlag.any?(bans)

  banned = try Database.with_connection(pool) do |db| holds?(db, bans, conn.remote_addr) end
  return ok(Bond.halt(conn, 429, "Too Many Requests")) if banned

  ok(conn)
end

# The flag says there may be a ban (or is not known yet, and is read now). The table is asked only then.
def holds?(db: Db.Connection, bans: ATS[String, Int], address: String) -> Result[Bool]
  return ok(false) if not BanFlag.known?(bans) and not try BanFlag.refresh(bans, db)

  Bans.banned?(db, address)
end

def require_sign_in(conn: Bond.Conn, pool: Database.Pool, pages: Optional[PageCache.Pages]) -> Result[Bond.Conn]
  return ok(conn) if public?(conn.path)

  # A read of a page that the cache keeps, with a session cookie, reads the version of the database first
  # (`PageCache.watch`), so that the person of the session can be the one kept for that version and the handler does
  # not read it again. A request with no cookie never reads the observer, and any other request looks the person up
  # as it always did.
  token = session_token(conn)
  return ok(conn) if not token.empty? and lookup_in_handler?(conn)

  watched = conn
  if (conn.method == "GET" or conn.method == "HEAD") and not token.empty? and PageCache.cached?(conn.path)
    watched = PageCache.watch(conn, pages)
  end

  user = try session_user(watched, pool, pages, token)
  case user
    some(person) -> ok(Bond.assign(watched, USER_KEY, person))
    none -> ok(Bond.redirect(watched, try entry_path(pool)))
  end
end

# The person of the session with `token` ("" for no cookie, which is no person and reads nothing): the one kept for
# the version of the database that the request was read at, else the one the database gives, which is then kept.
def session_user(
  conn: Bond.Conn,
  pool: Database.Pool,
  pages: Optional[PageCache.Pages],
  token: String,
) -> Result[Optional[Auth.User]]
  return ok(none) if token.empty?

  seen = PageCache.seen(conn)
  kept = PageCache.known_user(pages, seen, token)
  return ok(kept) if kept.some?

  found = try Database.with_connection(pool) do |db| Auth.user_for(db, token) end
  case found
    some(session) ->
      PageCache.remember_user(pages, seen, token, session)
      ok(some(session.user))
    none -> ok(none)
  end
end

def public?(path: String) -> Bool
  return true if PUBLIC_PATHS.include?(path) or bot_api?(path)

  # The stylesheet and whatever else is in the assets folder: the sign-in page needs its style before anybody has
  # signed in. A path that is not a file there is a 404 (`Bond.static` refuses a way out of the folder), whoever asks.
  return true if path.start_with?(ASSETS_PREFIX)

  # "/join/CODE" splits into "", "join" and the code, "/qr_code/ID" alike, and "/session/transfers/TOKEN" into four.
  parts = path.split("/")
  return false if parts.empty? or not parts[0].empty? or parts.last.empty?

  return true if parts.size == JOIN_SEGMENTS and (parts[1] == "join" or parts[1] == "qr_code")

  parts.size == TRANSFER_SEGMENTS and parts[1] == "session" and parts[2] == "transfers"
end

def entry_path(pool: Database.Pool) -> Result[String]
  open = try first_run_open?(pool)
  return ok(Routes.FIRST_RUN) if open

  ok(Routes.SIGN_IN)
end

def first_run_open?(pool: Database.Pool) -> Result[Bool]
  Database.with_connection(pool) do |db| Auth.first_run?(db) end
end

def show_first_run(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  open = try first_run_open?(pool)
  return ok(Bond.redirect(conn, Routes.HOME)) if not open

  ok(Bond.html(conn, 200, Views.first_run("", "", "")))
end

def create_first_run(conn: Bond.Conn, pool: Database.Pool, slots: ATS[String, Int]) -> Result[Bond.Conn]
  name = try Bond.form(conn, "name")
  email = try Bond.form(conn, "email")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  # A closed app answers every form with a redirect and no hashing, so it never has to say 503: look before taking a
  # slot. `Auth.first_run` looks again once it has the connection, and inside the transaction.
  open = try first_run_open?(pool)
  return ok(Bond.redirect(conn, Routes.HOME)) if not open

  return ok(busy(conn)) if not Slots.take?(slots, MAX_HASHES)

  made = Database.with_connection(pool) do |db| Auth.first_run(db, name, email, password, agent, conn.remote_addr) end

  Slots.release(slots)
  outcome = try made
  case outcome
    Auth.FirstRun.Created(token) -> ok(signed_in(conn, token))
    Auth.FirstRun.Closed -> ok(Bond.redirect(conn, Routes.HOME))
    Auth.FirstRun.Invalid(message) -> ok(Bond.html(conn, 422, Views.first_run(name, email, message)))
  end
end

def show_join(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  code = Bond.param(conn, "code").unwrap_or("")
  valid = try join_code_valid?(pool, code)
  return ok(not_found(conn)) if not valid

  ok(private_page(Bond.html(conn, 200, Views.join(code, "", "", ""))))
end

# The code is looked at first and the form after it, so a wrong code is the same 404 whatever is posted. The hashing
# slot is taken only for a code and a form that work, and the code is looked at again in the transaction
# of `Auth.join`.
def create_join(conn: Bond.Conn, pool: Database.Pool, slots: ATS[String, Int]) -> Result[Bond.Conn]
  code = Bond.param(conn, "code").unwrap_or("")
  valid = try join_code_valid?(pool, code)
  return ok(not_found(conn)) if not valid

  name = try Bond.form(conn, "name")
  email = try Bond.form(conn, "email")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  # A form that cannot work (a bad value, an email that has an account) is answered before a slot is taken, since
  # it needs
  # no hashing; `Auth.join` looks again, and the transaction once more.
  problem = try join_problem(pool, name, email, password)
  return ok(private_page(Bond.html(conn, 422, Views.join(code, name, email, problem)))) if problem != ""

  if not Slots.take?(slots, MAX_HASHES)
    return ok(retry_later(private_page(Bond.html(conn, 503, Views.join(code, name, email, Failure.BUSY)))))
  end

  joined = Database.with_connection(pool) do |db|
    Auth.join(db, code, name, email, password, agent, conn.remote_addr)
  end

  Slots.release(slots)
  outcome = try joined
  case outcome
    Auth.JoinOutcome.Joined(token) -> ok(signed_in(conn, token))
    Auth.JoinOutcome.Gone -> ok(not_found(conn))
    Auth.JoinOutcome.Invalid(message) -> ok(private_page(Bond.html(conn, 422, Views.join(code, name, email, message))))
  end
end

def join_problem(pool: Database.Pool, name: String, email: String, password: String) -> Result[String]
  Database.with_connection(pool) do |db| Auth.join_problem(db, name, email, password) end
end

def join_code_valid?(pool: Database.Pool, code: String) -> Result[Bool]
  Database.with_connection(pool) do |db| Accounts.join_code_valid?(db, code) end
end

def not_found(conn: Bond.Conn) -> Bond.Conn = Bond.text(conn, 404, Routes.MISSING)

def show_sign_in(conn: Bond.Conn, pool: Database.Pool, mailer: Mailer.Mailer) -> Result[Bond.Conn]
  open = try first_run_open?(pool)
  return ok(Bond.redirect(conn, Routes.FIRST_RUN)) if open

  user = try current_user(conn, pool)
  case user
    some(_) -> ok(Bond.redirect(conn, Routes.HOME))
    none -> ok(Bond.html(conn, 200, Views.sign_in("", "", Mailer.enabled?(mailer))))
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
  return ok(Bond.header(Bond.html(conn, 429, Views.busy(TOO_MANY)), "retry-after", wait.to_s)) if wait > 0

  email = try Bond.form(conn, "email_address")
  password = try Bond.form(conn, "password")
  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  return ok(busy(conn)) if not Slots.take?(slots, MAX_HASHES)

  checked = Database.with_connection(pool) do |db|
    Auth.sign_in(db, email, password, agent, conn.remote_addr, config.bcrypt_library)
  end

  Slots.release(slots)
  token = try checked
  case token
    some(value) -> ok(signed_in(conn, value))
    none -> ok(Bond.html(conn, 422, Views.sign_in(email, BAD_LOGIN, Mailer.enabled?(mailer))))
  end
end

# The sockets of the person are told to reconnect: the ones of their other sessions are welcomed again at once, and
# the ones of this browser are refused, since its cookie is gone (`Hangup`).
def destroy_session(conn: Bond.Conn, pool: Database.Pool, hub: Channels.Hub) -> Result[Bond.Conn]
  person = try assigned_user(conn)
  token = Bond.get_session(conn, TOKEN_KEY)
  cleared = Bond.clear_session(conn)
  return ok(Bond.redirect(cleared, Routes.SIGN_IN)) if not token.ok?

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

  ok(Bond.redirect(cleared, Routes.SIGN_IN))
end

# Without email there is nothing to send a link with, so the pages of the reset are not there (a fact about the app,
# the same for every visitor).
def show_forgot_password(conn: Bond.Conn, mailer: Mailer.Mailer) -> Result[Bond.Conn]
  return ok(Bond.text(conn, 404, Routes.MISSING)) if not Mailer.enabled?(mailer)

  ok(Bond.html(conn, 200, Views.forgot_password()))
end

# The answer is the page of `Views.reset_requested` whatever the email is (and whatever the mailer does with the
# message), so the form does not tell who has an account. The sending is the mailer's, off this request.
def create_password_reset(
  conn: Bond.Conn,
  config: Config,
  pool: Database.Pool,
  mailer: Mailer.Mailer,
) -> Result[Bond.Conn]
  return ok(Bond.text(conn, 404, Routes.MISSING)) if not Mailer.enabled?(mailer)

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

  ok(Bond.html(conn, 200, Views.reset_requested()))
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
  Smtp.Message(
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
  return ok(link_gone(conn)) if not valid

  ok(private_page(Bond.html(conn, 200, Views.reset_password(token, ""))))
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
  return ok(link_gone(conn)) if not valid

  return ok(busy_reset_form(conn, token)) if not Slots.take?(slots, MAX_HASHES)

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
      ok(signed_in(conn, session))
    Auth.ResetOutcome.Gone -> ok(link_gone(conn))
    Auth.ResetOutcome.Invalid(message) -> ok(private_page(Bond.html(conn, 422, Views.reset_password(token, message))))
  end
end

def reset_token_valid?(pool: Database.Pool, token: String) -> Result[Bool]
  Database.with_connection(pool) do |db| Auth.reset_token_valid?(db, token) end
end

def link_gone(conn: Bond.Conn) -> Bond.Conn = private_page(Bond.html(conn, 410, Views.reset_link_gone()))

# 503 for a burst of requests that hash, and when to ask again. Nothing of the form is shown again.
def busy(conn: Bond.Conn) -> Bond.Conn = retry_later(Bond.html(conn, 503, Views.busy(Failure.BUSY)))

# The form comes back with the token, so a person does not have to ask for another link because of a burst.
def busy_reset_form(conn: Bond.Conn, token: String) -> Bond.Conn
  retry_later(private_page(Bond.html(conn, 503, Views.reset_password(token, Failure.BUSY))))
end

def retry_later(conn: Bond.Conn) -> Bond.Conn = Bond.header(conn, "retry-after", Failure.RETRY_AFTER_SECONDS)

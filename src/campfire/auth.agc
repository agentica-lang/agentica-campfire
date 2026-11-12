## First run, joining with a code, sign in, sign out and password reset over the `accounts`, `users`, `sessions` and
## `password_resets` tables. These functions take an open connection and never see a request. A session is a row with a
## random token that the cookie carries, so deleting the row ends the session on the server whatever cookie a client
## keeps. The token is not hashed in the table: the cookie that holds it is signed, so a copy of the database alone does
## not give a session. `ip_address` is the address of the client that started the session ("" when the caller has none).

import Db from "pkg/db/db"
import Accounts from "accounts"
import Passwords from "passwords"
import Rooms from "rooms"
import Rails from "repo/rails"
import {int_of, text_of} from "repo/rows"

## The name of the account that the first run makes, and of the open room that it starts with (as upstream does).
export ACCOUNT_NAME = "Campfire"
export FIRST_ROOM_NAME = "All Talk"

MAX_NAME_LENGTH = 100
MAX_EMAIL_LENGTH = 254
TOKEN_BYTES = 32
EMAIL_TAKEN = "An account with that email exists already"

# A reset link works for this long. While a link works nobody gets another one, and after it was used a new one comes
# only this long after it was made: a stranger who types an email into the form can neither make the app send mail to
# that address more often than that, nor replace the link that the person is about to open.
export RESET_MINUTES = 30
RESEND_SECONDS = 300

# A session works for this long, as the cookie does (the web side takes its `max_age` from here): a row older than that
# is dead whatever the cookie says (`user_for` refuses it, and `purge_sessions` removes it).
export SESSION_SECONDS = 2_592_000

# `last_active_at` is written at most this often per session, so a busy tab does not write on every request.
TOUCH_SECONDS = 300

# A reset token is TOKEN_BYTES of hex, which is 64 characters: nothing longer is looked up.
MAX_TOKEN_LENGTH = 128

# The time as the schema writes it (Rails' form, see `repo/rails.agc`), and the times that the rules below count from.
NOW = Rails.NOW
RESET_EXPIRY = "strftime('#{Rails.STAMP}', 'now', '+#{RESET_MINUTES} minutes')"
RESEND_LIMIT = "strftime('#{Rails.STAMP}', 'now', '-#{RESEND_SECONDS} seconds')"
SESSION_EXPIRY = "strftime('#{Rails.STAMP}', 'now', '-#{SESSION_SECONDS} seconds')"
# The second at which a session row stops working (Unix seconds): `user_for` and `seconds_left` both count from it.
SESSION_ENDS = "coalesce(cast(strftime('%s', sessions.created_at) as integer), 0) + #{SESSION_SECONDS}"
TOUCH_LIMIT = "strftime('#{Rails.STAMP}', 'now', '-#{TOUCH_SECONDS} seconds')"

## A person who is signed in.
export struct User
  id: Int
  name: String
  role: String
end

## A person who is signed in, and when their session stops working (Unix ms), which a copy of the person must not
## outlive.
export struct Session
  user: User
  ends_at_ms: Int
end

## What the email of a password reset needs: the name and the address of the person, and the token that goes in the
## link (it is not kept: the table has its hash).
export struct PasswordReset
  name: String
  email: String
  token: String
end

# Who a session is for, as far as the server knows: the `User-Agent` and the address of the client, each ""
# when unknown.
struct Client
  user_agent: String
  ip_address: String
end

## What setting a new password with a reset link did. `SignedIn` holds the token of the new session and the id of the
## person, whose other sessions it ended. `Gone` is a link
## that does not work (unknown, used, expired, or its person was deactivated). `Invalid` holds what is wrong with the
## password, to show again; the link is still good.
export enum ResetOutcome
  SignedIn(String, Int)
  Gone
  Invalid(String)
end

## What the first run did. `Created` holds the token of the session of the new administrator. `Closed` is an app that
## already has its account. `Invalid` holds what is wrong with the form, to show again.
export enum FirstRun
  Created(String)
  Closed
  Invalid(String)
end

## What joining with a code did. `Joined` holds the token of the session of the new person. `Gone` is a code that is not
## the account's (unknown, or the old one of a regenerated code). `Invalid` holds what is wrong with the form, to show
## again.
export enum JoinOutcome
  Joined(String)
  Gone
  Invalid(String)
end

## True while the app has no account: the first run has not happened.
export def first_run?(conn: Db.Connection) -> Result[Bool]
  exists = try account_exists?(conn)
  ok(not exists)
end

## Makes the account, its administrator and the open room "All Talk", and signs them in, in one transaction that
## checks again that there is no account, so two forms sent together make one. `password` is hashed before the
## transaction starts, since hashing is slow and the transaction holds the write lock. An `error` is a database or
## hashing failure, not a bad form.
export def first_run(
  conn: Db.Connection,
  name: String,
  email: String,
  password: String,
  user_agent: String,
  ip_address: String,
) -> Result[FirstRun]
  # Before the form and the hashing: once the app has its account, any form is a redirect and costs nothing. The
  # transaction below checks again, for the forms that were sent together.
  exists = try account_exists?(conn)
  return ok(FirstRun.Closed) if exists

  problem = form_problem(name, email, password)
  return ok(FirstRun.Invalid(problem)) if problem != ""

  digest = try Passwords.hash(password)
  token = OpenSSL.Random.hex(TOKEN_BYTES)
  client = Client(user_agent: user_agent, ip_address: ip_address)
  made = try Db.transaction(conn) do |tx| make_account(tx, name.strip, normal(email), digest, token, client) end
  return ok(FirstRun.Created(token)) if made

  ok(FirstRun.Closed)
end

## Makes a member of the account for the person who used the join code, puts them in every open room that exists and
## signs them in, in one transaction that checks again that the code is still the account's and that nobody took the
## email, so forms that arrive together with one email make one person. `password` is hashed before the transaction
## starts, since hashing is slow and the transaction holds the write lock; the code and the email are looked at before
## the hashing too, so a form that cannot work costs none. An `error` is a database or hashing failure, not a bad form.
export def join(
  conn: Db.Connection,
  code: String,
  name: String,
  email: String,
  password: String,
  user_agent: String,
  ip_address: String,
) -> Result[JoinOutcome]
  valid = try Accounts.join_code_valid?(conn, code)
  return ok(JoinOutcome.Gone) if not valid

  problem = try join_problem(conn, name, email, password)
  return ok(JoinOutcome.Invalid(problem)) if problem != ""

  digest = try Passwords.hash(password)
  join_hashed(conn, code, name, email, digest, user_agent, ip_address)
end

## What is wrong with a join form, or "": a name, email or password that does not do, or an email that has an account
## already. It hashes nothing, so the web layer asks it before it takes a hashing slot.
export def join_problem(conn: Db.Connection, name: String, email: String, password: String) -> Result[String]
  problem = form_problem(name, email, password)
  return ok(problem) if problem != ""

  taken = try email_taken?(conn, normal(email))
  return ok(EMAIL_TAKEN) if taken

  ok("")
end

## The write half of `join`, for a password that is hashed already: the transaction, which checks again that the code
## is the account's and that the email is free. `join` has looked at both before the hashing, so only a code that was
## regenerated, or an email that was taken, while the password was being hashed gets here; the specs call this to
## reach those checks directly.
export def join_hashed(
  conn: Db.Connection,
  code: String,
  name: String,
  email: String,
  digest: String,
  user_agent: String,
  ip_address: String,
) -> Result[JoinOutcome]
  token = OpenSSL.Random.hex(TOKEN_BYTES)
  client = Client(user_agent: user_agent, ip_address: ip_address)
  Db.transaction(conn) do |tx| make_member(tx, code, name.strip, normal(email), digest, token, client) end
end

## Starts a session for the user whose email and password these are and gives its token, or `none` when the email is
## not a person's (a bot has none), the user is deactivated or the password is wrong. The three look alike, in answer
## and in time. `bcrypt_library` is `CAMPFIRE_BCRYPT_LIBRARY`, for the check of a bcrypt digest.
export def sign_in(
  conn: Db.Connection,
  email: String,
  password: String,
  user_agent: String,
  ip_address: String,
  bcrypt_library: String = "",
) -> Result[Optional[String]]
  # Nothing that long is a real email or password, and hashing one is work that a stranger could ask for.
  if email.length > MAX_EMAIL_LENGTH or password.bytes.size > Passwords.MAX_BYTES
    Passwords.verify_nobody?()
    return ok(none)
  end

  rows = try find_person(conn, "id, password_digest", normal(email))

  if rows.empty?
    Passwords.verify_nobody?()
    return ok(none)
  end

  # An `error` is a bcrypt digest that this system cannot check: it fails the request (a 500 with the reason in the
  # log) and does not say "wrong password" to someone who typed the right one.
  verified = try Passwords.verify(password, text_of(rows[0], "password_digest"), bcrypt_library)
  return ok(none) if not verified

  open_session(conn, int_of(rows[0], "id"), user_agent, ip_address)
end

## The session of a person who just proved their password, or `none` when they were deactivated meanwhile. The insert
## reads `status` itself, in the one statement, so a deactivation that commits first leaves no row, and one that
## commits after it deletes the row: no session survives for a later reactivation to revive.
export def open_session(
  conn: Db.Connection,
  user_id: Int,
  user_agent: String,
  ip_address: String,
) -> Result[Optional[String]]
  try purge_sessions(conn)
  token = OpenSSL.Random.hex(TOKEN_BYTES)
  inserted = try Db.execute(
    conn,
    "insert into sessions (user_id, token, user_agent, ip_address, last_active_at, created_at, updated_at) " +
    "select id, ?, ?, ?, #{NOW}, #{NOW}, #{NOW} from users where id = ? and status = #{Rails.ACTIVE}",
    [Db.Value.Text(token), text_or_null(user_agent), text_or_null(ip_address), Db.Value.Int(user_id)],
  )

  return ok(none) if inserted == 0

  ok(some(token))
end

## The session with this token and its user, or `none` when there is no such session, it is older than the cookie life
## (`SESSION_SECONDS`, whether or not `purge_sessions` has removed it yet) or its user is deactivated. A session that
## was last active more than five minutes ago is marked active now; a request inside that time only reads.
export def user_for(conn: Db.Connection, token: String) -> Result[Optional[Session]]
  rows = try Db.query(
    conn,
    "select users.id, users.name, users.role, (#{SESSION_ENDS}) * 1000 as ends_at_ms, " +
    "sessions.last_active_at < #{TOUCH_LIMIT} as stale " +
    "from sessions join users on users.id = sessions.user_id where sessions.token = ? and " +
    "sessions.created_at >= #{SESSION_EXPIRY} and users.status = #{Rails.ACTIVE}",
    [Db.Value.Text(token)],
  )

  return ok(none) if rows.empty?

  if int_of(rows[0], "stale") == 1
    touch_session(conn, token)
  end

  person = User(
    id: int_of(rows[0], "id"),
    name: text_of(rows[0], "name"),
    role: Rails.role_name(int_of(rows[0], "role")),
  )

  ok(some(Session(user: person, ends_at_ms: int_of(rows[0], "ends_at_ms"))))
end

## How many seconds the session with this token has before it is as old as a cookie lives (`SESSION_SECONDS`): the
## time after which `purge_sessions` removes it. 0 for a session that is not there, is older, or is of a deactivated
## person. A socket that holds the session is closed at the next check that finds 0 (`CableWeb`), not at that time.
export def seconds_left(conn: Db.Connection, token: String) -> Result[Int]
  rows = try Db.query(
    conn,
    "select #{SESSION_ENDS} - cast(strftime('%s', 'now') as integer) as remaining " +
    "from sessions join users on users.id = sessions.user_id where sessions.token = ? and " +
    "users.status = #{Rails.ACTIVE}",
    [Db.Value.Text(token)],
  )

  return ok(0) if rows.empty?

  remaining = int_of(rows[0], "remaining")
  return ok(0) if remaining < 0

  ok(remaining)
end

## Ends the session with this token. A token that is not there is not an error.
export def sign_out(conn: Db.Connection, token: String) -> Result[Void]
  try Db.execute(conn, "delete from sessions where token = ?", [Db.Value.Text(token)])
  ok()
end

## Makes a reset link for the person with this email, and gives what the email needs, or `none` when nothing is to be
## sent: no such person, a deactivated one or a bot, an address that is too long, a link of that person that still
## works (a request must not replace it, or a stranger could keep the person from ever using one), or a link made less
## than five minutes ago. The caller answers the same whatever this gives. The expired links of everybody go with it.
## It is one transaction, which takes the write lock first, so requests that come together find each other's link and
## only one of them sends.
export def request_password_reset(conn: Db.Connection, email: String) -> Result[Optional[PasswordReset]]
  return ok(none) if email.length > MAX_EMAIL_LENGTH

  token = OpenSSL.Random.hex(TOKEN_BYTES)
  Db.transaction(conn) do |tx| make_reset(tx, normal(email), token) end
end

## Deletes the link of this token, if it was not used: for a link that was made and could not be sent, which would
## otherwise keep the person from having another for as long as it works. A token that is not there is not an error.
export def cancel_password_reset(conn: Db.Connection, token: String) -> Result[Void]
  try Db.execute(
    conn,
    "delete from password_resets where token_digest = ? and used_at is null",
    [Db.Value.Text(token_digest(token))],
  )

  ok()
end

## True when the token belongs to a link that has not been used or expired. It changes nothing, so a page may call it.
export def reset_token_valid?(conn: Db.Connection, token: String) -> Result[Bool]
  return ok(false) if token.empty? or token.length > MAX_TOKEN_LENGTH

  rows = try Db.query(
    conn,
    "select count(*) as total from password_resets where token_digest = ? and used_at is null and expires_at > #{NOW}",
    [Db.Value.Text(token_digest(token))],
  )

  ok(int_of(rows[0], "total") > 0)
end

## Sets the new password of the person that the link belongs to, ends every session that they had, starts a new one and
## uses up the link, in one transaction: two forms sent together with one link make one change, since the update that
## marks the link used tells which of them got it. The link is looked at before the password is hashed, so a link that
## does not work costs no hashing. The web layer looks at it too, before it takes a hash slot: a link that does not
## work is answered at once, even while the slots are all busy, and this function stays right for any other caller. An
## `error` is a database or hashing failure.
export def reset_password(
  conn: Db.Connection,
  token: String,
  password: String,
  user_agent: String,
  ip_address: String,
) -> Result[ResetOutcome]
  valid = try reset_token_valid?(conn, token)
  return ok(ResetOutcome.Gone) if not valid

  problem = Passwords.problem(password)
  return ok(ResetOutcome.Invalid(problem)) if problem != ""

  digest = try Passwords.hash(password)
  session = OpenSSL.Random.hex(TOKEN_BYTES)
  client = Client(user_agent: user_agent, ip_address: ip_address)
  made = try Db.transaction(conn) do |tx| finish_reset(tx, token, digest, session, client) end
  return ok(ResetOutcome.SignedIn(session, made.unwrap!)) if made.some?

  ok(ResetOutcome.Gone)
end

## True when `email` (in the `normal` form) is a single `@` between a name and a domain with a dot, with no space
## and not too long: enough to catch a typo. Only a mail sent to the address proves that it works.
export def valid_email?(email: String) -> Bool
  parts = email.split("@")
  return false if parts.size != 2 or email.length > MAX_EMAIL_LENGTH or email.include?(" ")

  not parts[0].empty? and parts[1].include?(".") and not parts[1].start_with?(".") and not parts[1].end_with?(".")
end

## Emails compare without case and without the spaces around them. The unique index of `email_address` compares bytes
## (it is Rails' own, and Rails stores an address as it was typed), so the app stores this form and looks an address up
## by it first, which the index serves. Only when no row has it does the lookup fall back to `lower(email_address)`,
## which scans `users`: a row that Rails made as `David@37signals.com` signs in as `david@37signals.com`, and is not
## made twice by a join. Where two rows differ only in case (the index lets Rails make them), the one that is already
## lower case is the person, and among the others the oldest.
export def normal(email: String) -> String = email.strip.downcase

## True when an account has `email` (in the `normal` form), in any status: the unique index compares bytes, so the
## lookup falls back to `lower(email_address)`, which finds a row that Rails made with capitals.
def email_taken?(conn: Db.Connection, email: String) -> Result[Bool]
  exact = try Db.query(conn, "select 1 from users where email_address = ? limit 1", [Db.Value.Text(email)])
  return ok(true) if not exact.empty?

  rows = try Db.query(conn, "select 1 from users where lower(email_address) = ? limit 1", [Db.Value.Text(email)])
  ok(not rows.empty?)
end

# What is wrong with the first-run form, or "".
def form_problem(name: String, email: String, password: String) -> String
  return "Enter your name" if name.strip.empty? or name.strip.length > MAX_NAME_LENGTH

  return "Enter a valid email address" if not valid_email?(normal(email))

  Passwords.problem(password)
end

# The rows (at most one) of the active person, not a bot, whose email is `email` in the normal form, with `columns`.
def find_person(conn: Db.Connection, columns: String, email: String) -> Result[List[Db.Row]]
  allowed = "status = #{Rails.ACTIVE} and role <> #{Rails.BOT}"
  exact = try Db.query(
    conn,
    "select #{columns} from users where email_address = ? and #{allowed} order by id limit 1",
    [Db.Value.Text(email)],
  )

  return ok(exact) if not exact.empty?

  Db.query(
    conn,
    "select #{columns} from users where lower(email_address) = ? and #{allowed} order by id limit 1",
    [Db.Value.Text(email)],
  )
end

# The body of `request_password_reset`: a link only for an active person who has no link that works and none made
# within the resend time. The person's earlier rows (used, expired) go when a new link is made.
def make_reset(tx: Db.Connection, email: String, token: String) -> Result[Optional[PasswordReset]]
  rows = try find_person(tx, "id, name, email_address", email)

  return ok(none) if rows.empty?

  user_id = int_of(rows[0], "id")
  held = try Db.query(
    tx,
    "select count(*) as total from password_resets where user_id = ? and " +
    "((used_at is null and expires_at > #{NOW}) or created_at > #{RESEND_LIMIT})",
    [Db.Value.Int(user_id)],
  )

  return ok(none) if int_of(held[0], "total") > 0

  try Db.execute(tx, "delete from password_resets where user_id = ? or expires_at <= #{NOW}", [Db.Value.Int(user_id)])
  try Db.execute(
    tx,
    "insert into password_resets (user_id, token_digest, expires_at) values (?, ?, #{RESET_EXPIRY})",
    [Db.Value.Int(user_id), Db.Value.Text(token_digest(token))],
  )

  ok(some(PasswordReset(name: text_of(rows[0], "name"), email: text_of(rows[0], "email_address"), token: token)))
end

# The hash of a token, as the table keeps it.
def token_digest(token: String) -> String = OpenSSL.Digest.sha256_hexdigest(token.bytes)

# `none` when the link was used or expired since it was looked at, or when its person is gone, with no session started;
# else the id of the person.
def finish_reset(
  tx: Db.Connection,
  token: String,
  digest: String,
  session: String,
  client: Client,
) -> Result[Optional[Int]]
  used = try Db.query(
    tx,
    "update password_resets set used_at = #{NOW} where token_digest = ? and used_at is null and expires_at > #{NOW} " +
    "returning user_id",
    [Db.Value.Text(token_digest(token))],
  )

  return ok(none) if used.empty?

  user_id = int_of(used[0], "user_id")
  changed = try Db.execute(
    tx,
    "update users set password_digest = ?, updated_at = #{NOW} where id = ? and status = #{Rails.ACTIVE} and " +
    "role <> #{Rails.BOT}",
    [Db.Value.Text(digest), Db.Value.Int(user_id)],
  )

  return ok(none) if changed == 0

  try Db.execute(tx, "delete from sessions where user_id = ?", [Db.Value.Int(user_id)])
  try Db.execute(tx, "delete from password_resets where user_id = ? and used_at is null", [Db.Value.Int(user_id)])
  try insert_session(tx, user_id, session, client)
  ok(some(user_id))
end

def account_exists?(conn: Db.Connection) -> Result[Bool]
  rows = try Db.query(conn, "select count(*) as total from accounts", [])
  ok(int_of(rows[0], "total") > 0)
end

# True when it made the account; false when there is one, with nothing written. The insert of the account is also
# refused by the unique `singleton_guard`, and the transaction takes the write lock before the count, so a second first
# run waits and then finds the account.
def make_account(
  tx: Db.Connection,
  name: String,
  email: String,
  digest: String,
  token: String,
  client: Client,
) -> Result[Bool]
  exists = try account_exists?(tx)
  return ok(false) if exists

  try Db.execute(
    tx,
    "insert into accounts (name, join_code, created_at, updated_at) values (?, ?, #{NOW}, #{NOW})",
    [Db.Value.Text(ACCOUNT_NAME), Db.Value.Text(Accounts.new_join_code())],
  )

  users = try Db.query(
    tx,
    "insert into users (name, email_address, password_digest, role, status, created_at, updated_at) " +
    "values (?, ?, ?, ?, ?, #{NOW}, #{NOW}) returning id",
    [
      Db.Value.Text(name),
      Db.Value.Text(email),
      Db.Value.Text(digest),
      Db.Value.Int(Rails.ADMINISTRATOR),
      Db.Value.Int(Rails.ACTIVE),
    ],
  )

  admin_id = int_of(users[0], "id")
  try Rooms.create_open_in(tx, admin_id, FIRST_ROOM_NAME)
  try insert_session(tx, admin_id, token, client)
  ok(true)
end

# The body of `join_hashed`. The email is looked at inside the transaction (it holds the write lock), so the second of
# two forms for one address finds the person that the first made, and the unique index is never what refuses it.
# Everybody who has the address is counted, a deactivated person too: only an administrator brings them back.
def make_member(
  tx: Db.Connection,
  code: String,
  name: String,
  email: String,
  digest: String,
  token: String,
  client: Client,
) -> Result[JoinOutcome]
  valid = try Accounts.join_code_valid?(tx, code)
  return ok(JoinOutcome.Gone) if not valid

  taken = try email_taken?(tx, email)
  return ok(JoinOutcome.Invalid(EMAIL_TAKEN)) if taken

  users = try Db.query(
    tx,
    "insert into users (name, email_address, password_digest, role, status, created_at, updated_at) " +
    "values (?, ?, ?, ?, ?, #{NOW}, #{NOW}) returning id",
    [
      Db.Value.Text(name),
      Db.Value.Text(email),
      Db.Value.Text(digest),
      Db.Value.Int(Rails.MEMBER),
      Db.Value.Int(Rails.ACTIVE),
    ],
  )

  user_id = int_of(users[0], "id")
  try Rooms.grant_open_rooms(tx, user_id)
  try insert_session(tx, user_id, token, client)
  ok(JoinOutcome.Joined(token))
end

def insert_session(conn: Db.Connection, user_id: Int, token: String, client: Client) -> Result[Int]
  try purge_sessions(conn)
  Db.execute(
    conn,
    "insert into sessions (user_id, token, user_agent, ip_address, last_active_at, created_at, updated_at) " +
    "values (?, ?, ?, ?, #{NOW}, #{NOW}, #{NOW})",
    [Db.Value.Int(user_id), Db.Value.Text(token), text_or_null(client.user_agent), text_or_null(client.ip_address)],
  )
end

# A missed touch is not worth failing the request for (the page is a read, and the next request tries again), so its
# result is dropped.
def touch_session(conn: Db.Connection, token: String) -> Void
  _ = Db.execute(
    conn,
    "update sessions set last_active_at = #{NOW}, updated_at = #{NOW} where token = ?",
    [Db.Value.Text(token)],
  )
end

# Removes the sessions that no cookie can use any more: those older than the cookie life, and those of a person who is
# deactivated (deactivating ends them already; this is the net for a row that gets past it). It runs whenever a session
# starts, since that is already a write, and a sign-in is the only time the table grows.
def purge_sessions(conn: Db.Connection) -> Result[Int]
  Db.execute(
    conn,
    "delete from sessions where created_at < #{SESSION_EXPIRY} or " +
    "user_id in (select id from users where status <> #{Rails.ACTIVE})",
    [],
  )
end

def text_or_null(text: String) -> Db.Value
  return Db.Value.Null if text.empty?

  Db.Value.Text(text)
end

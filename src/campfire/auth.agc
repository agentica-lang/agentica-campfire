## First run, joining with a code, sign in, sign out and password reset over the `accounts`, `users`, `sessions` and
## `password_resets` tables. These functions take an open connection and never see a request. A session is a row with a
## random token that the cookie carries, so deleting the row ends the session on the server whatever cookie a client
## keeps. The token is not hashed in the table: the cookie that holds it is signed, so a copy of the database alone does
## not give a session.

import Db from "pkg/db/db"
import Accounts from "accounts"
import Passwords from "passwords"
import Rooms from "rooms"
import {int_of, text_of} from "repo/rows"

# The name of the account that the first run makes, and of the open room that it starts with (as upstream does).
ACCOUNT_NAME = "Campfire"
FIRST_ROOM_NAME = "All Talk"

MAX_NAME_LENGTH = 100
MAX_EMAIL_LENGTH = 254
TOKEN_BYTES = 32
EMAIL_TAKEN = "An account with that email exists already"

# A reset link works for this long. While a link works nobody gets another one, and after it was used a new one comes
# only this long after it was made: a stranger who types an email into the form can neither make the app send mail to
# that address more often than that, nor replace the link that the person is about to open.
export RESET_MINUTES = 30
RESEND_SECONDS = 300

# A reset token is TOKEN_BYTES of hex, which is 64 characters: nothing longer is looked up.
MAX_TOKEN_LENGTH = 128

# The time as the schema writes it (see `repo/migrations.agc`), and the time that a reset link lasts to.
NOW = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
RESET_EXPIRY = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+#{RESET_MINUTES} minutes')"
RESEND_LIMIT = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-#{RESEND_SECONDS} seconds')"

## A person who is signed in.
export struct User
  id: Int
  name: String
  role: String
end

## What the email of a password reset needs: the name and the address of the person, and the token that goes in the
## link (it is not kept: the table has its hash).
export struct PasswordReset
  name: String
  email: String
  token: String
end

## What setting a new password with a reset link did. `SignedIn` holds the token of the new session. `Gone` is a link
## that does not work (unknown, used, expired, or its person was deactivated). `Invalid` holds what is wrong with the
## password, to show again; the link is still good.
export enum ResetOutcome
  SignedIn(String)
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
  return ok(not exists)
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
) -> Result[FirstRun]
  # Before the form and the hashing: once the app has its account, any form is a redirect and costs nothing. The
  # transaction below checks again, for the forms that were sent together.
  exists = try account_exists?(conn)
  if exists
    return ok(FirstRun.Closed)
  end

  problem = form_problem(name, email, password)
  if problem != ""
    return ok(FirstRun.Invalid(problem))
  end

  digest = try Passwords.hash(password)
  token = SecureRandom.hex(TOKEN_BYTES)
  made = try Db.transaction(conn) do |tx| make_account(tx, name.strip, normal(email), digest, token, user_agent) end
  if made
    return ok(FirstRun.Created(token))
  end

  return ok(FirstRun.Closed)
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
) -> Result[JoinOutcome]
  valid = try Accounts.join_code_valid?(conn, code)
  if not valid
    return ok(JoinOutcome.Gone)
  end

  problem = try join_problem(conn, name, email, password)
  if problem != ""
    return ok(JoinOutcome.Invalid(problem))
  end

  digest = try Passwords.hash(password)
  return join_hashed(conn, code, name, email, digest, user_agent)
end

## What is wrong with a join form, or "": a name, email or password that does not do, or an email that has an account
## already. It hashes nothing, so the web layer asks it before it takes a hashing slot.
export def join_problem(conn: Db.Connection, name: String, email: String, password: String) -> Result[String]
  problem = form_problem(name, email, password)
  if problem != ""
    return ok(problem)
  end

  taken = try email_taken?(conn, normal(email))
  if taken
    return ok(EMAIL_TAKEN)
  end

  return ok("")
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
) -> Result[JoinOutcome]
  token = SecureRandom.hex(TOKEN_BYTES)
  return Db.transaction(conn) do |tx| make_member(tx, code, name.strip, normal(email), digest, token, user_agent) end
end

## Starts a session for the user whose email and password these are and gives its token, or `none` when the email is
## not a person's (a bot has none), the user is deactivated or the password is wrong. The three look alike, in answer
## and in time.
export def sign_in(
  conn: Db.Connection,
  email: String,
  password: String,
  user_agent: String,
) -> Result[Optional[String]]
  # Nothing that long is a real email or password, and hashing one is work that a stranger could ask for.
  if email.length > MAX_EMAIL_LENGTH or password.bytes.size > Passwords.MAX_BYTES
    Passwords.verify_nobody?()
    return ok(none)
  end

  rows = try Db.query(
    conn,
    "select id, password_digest from users where email = ? and active = 1 and role <> 'bot'",
    [Db.Value.Text(normal(email))],
  )

  if rows.empty?
    Passwords.verify_nobody?()
    return ok(none)
  end

  if not Passwords.verify?(password, text_of(rows[0], "password_digest"))
    return ok(none)
  end

  return open_session(conn, int_of(rows[0], "id"), user_agent)
end

## The session of a person who just proved their password, or `none` when they were deactivated meanwhile. The insert
## reads `active` itself, in the one statement, so a deactivation that commits first leaves no row, and one that commits
## after it deletes the row: no session survives for a later reactivation to revive.
export def open_session(conn: Db.Connection, user_id: Int, user_agent: String) -> Result[Optional[String]]
  token = SecureRandom.hex(TOKEN_BYTES)
  inserted = try Db.execute(
    conn,
    "insert into sessions (user_id, token, user_agent) select id, ?, ? from users where id = ? and active = 1",
    [Db.Value.Text(token), text_or_null(user_agent), Db.Value.Int(user_id)],
  )

  if inserted == 0
    return ok(none)
  end

  return ok(some(token))
end

## The user of the session with this token, or `none` when there is no such session or its user is deactivated.
export def user_for(conn: Db.Connection, token: String) -> Result[Optional[User]]
  rows = try Db.query(
    conn,
    "select users.id, users.name, users.role from sessions join users on users.id = sessions.user_id " +
    "where sessions.token = ? and users.active = 1",
    [Db.Value.Text(token)],
  )

  if rows.empty?
    return ok(none)
  end

  return ok(some(User(id: int_of(rows[0], "id"), name: text_of(rows[0], "name"), role: text_of(rows[0], "role"))))
end

## Ends the session with this token. A token that is not there is not an error.
export def sign_out(conn: Db.Connection, token: String) -> Result[Void]
  try Db.execute(conn, "delete from sessions where token = ?", [Db.Value.Text(token)])
  return ok()
end

## Makes a reset link for the person with this email, and gives what the email needs, or `none` when nothing is to be
## sent: no such person, a deactivated one or a bot, an address that is too long, a link of that person that still
## works (a request must not replace it, or a stranger could keep the person from ever using one), or a link made less
## than five minutes ago. The caller answers the same whatever this gives. The expired links of everybody go with it.
## It is one transaction, which takes the write lock first, so requests that come together find each other's link and
## only one of them sends.
export def request_password_reset(conn: Db.Connection, email: String) -> Result[Optional[PasswordReset]]
  if email.length > MAX_EMAIL_LENGTH
    return ok(none)
  end

  token = SecureRandom.hex(TOKEN_BYTES)
  return Db.transaction(conn) do |tx| make_reset(tx, normal(email), token) end
end

## Deletes the link of this token, if it was not used: for a link that was made and could not be sent, which would
## otherwise keep the person from having another for as long as it works. A token that is not there is not an error.
export def cancel_password_reset(conn: Db.Connection, token: String) -> Result[Void]
  try Db.execute(
    conn,
    "delete from password_resets where token_digest = ? and used_at is null",
    [Db.Value.Text(token_digest(token))],
  )

  return ok()
end

## True when the token belongs to a link that has not been used or expired. It changes nothing, so a page may call it.
export def reset_token_valid?(conn: Db.Connection, token: String) -> Result[Bool]
  if token.empty? or token.length > MAX_TOKEN_LENGTH
    return ok(false)
  end

  rows = try Db.query(
    conn,
    "select count(*) as total from password_resets where token_digest = ? and used_at is null and expires_at > #{NOW}",
    [Db.Value.Text(token_digest(token))],
  )

  return ok(int_of(rows[0], "total") > 0)
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
) -> Result[ResetOutcome]
  valid = try reset_token_valid?(conn, token)
  if not valid
    return ok(ResetOutcome.Gone)
  end

  problem = Passwords.problem(password)
  if problem != ""
    return ok(ResetOutcome.Invalid(problem))
  end

  digest = try Passwords.hash(password)
  session = SecureRandom.hex(TOKEN_BYTES)
  made = try Db.transaction(conn) do |tx| finish_reset(tx, token, digest, session, user_agent) end
  if made
    return ok(ResetOutcome.SignedIn(session))
  end

  return ok(ResetOutcome.Gone)
end

# What is wrong with the first-run form, or "".
def form_problem(name: String, email: String, password: String) -> String
  if name.strip.empty? or name.strip.length > MAX_NAME_LENGTH
    return "Enter your name"
  end

  if not valid_email?(normal(email))
    return "Enter a valid email address"
  end

  return Passwords.problem(password)
end

# A single `@` between a name and a domain with a dot, and no space: enough to catch a typo. Only a mail sent to the
# address proves that it works.
def valid_email?(email: String) -> Bool
  parts = email.split("@")
  if parts.size != 2 or email.length > MAX_EMAIL_LENGTH or email.include?(" ")
    return false
  end

  return (
    not parts[0].empty? and
    parts[1].include?(".") and
    not parts[1].start_with?(".") and
    not parts[1].end_with?(".")
  )
end

# Emails compare without case and without the spaces around them (the column is `collate nocase`, and this keeps the
# stored value the one that a person types again).
def normal(email: String) -> String
  return email.strip.downcase
end

# The body of `request_password_reset`: a link only for an active person who has no link that works and none made
# within the resend time. The person's earlier rows (used, expired) go when a new link is made.
def make_reset(tx: Db.Connection, email: String, token: String) -> Result[Optional[PasswordReset]]
  rows = try Db.query(
    tx,
    "select id, name, email from users where email = ? and active = 1 and role <> 'bot'",
    [Db.Value.Text(email)],
  )

  if rows.empty?
    return ok(none)
  end

  user_id = int_of(rows[0], "id")
  held = try Db.query(
    tx,
    "select count(*) as total from password_resets where user_id = ? and " +
    "((used_at is null and expires_at > #{NOW}) or created_at > #{RESEND_LIMIT})",
    [Db.Value.Int(user_id)],
  )

  if int_of(held[0], "total") > 0
    return ok(none)
  end

  try Db.execute(tx, "delete from password_resets where user_id = ? or expires_at <= #{NOW}", [Db.Value.Int(user_id)])
  try Db.execute(
    tx,
    "insert into password_resets (user_id, token_digest, expires_at) values (?, ?, #{RESET_EXPIRY})",
    [Db.Value.Int(user_id), Db.Value.Text(token_digest(token))],
  )

  return ok(some(PasswordReset(name: text_of(rows[0], "name"), email: text_of(rows[0], "email"), token: token)))
end

# The hash of a token, as the table keeps it.
def token_digest(token: String) -> String
  return Digest.sha256_hexdigest(token.bytes)
end

# False when the link was used or expired since it was looked at, or when its person is gone, with no session started.
def finish_reset(tx: Db.Connection, token: String, digest: String, session: String, user_agent: String) -> Result[Bool]
  used = try Db.query(
    tx,
    "update password_resets set used_at = #{NOW} where token_digest = ? and used_at is null and expires_at > #{NOW} " +
    "returning user_id",
    [Db.Value.Text(token_digest(token))],
  )

  if used.empty?
    return ok(false)
  end

  user_id = int_of(used[0], "user_id")
  changed = try Db.execute(
    tx,
    "update users set password_digest = ?, updated_at = #{NOW} where id = ? and active = 1 and role <> 'bot'",
    [Db.Value.Text(digest), Db.Value.Int(user_id)],
  )

  if changed == 0
    return ok(false)
  end

  try Db.execute(tx, "delete from sessions where user_id = ?", [Db.Value.Int(user_id)])
  try Db.execute(tx, "delete from password_resets where user_id = ? and used_at is null", [Db.Value.Int(user_id)])
  try insert_session(tx, user_id, session, user_agent)
  return ok(true)
end

def account_exists?(conn: Db.Connection) -> Result[Bool]
  rows = try Db.query(conn, "select count(*) as total from accounts", [])
  return ok(int_of(rows[0], "total") > 0)
end

# True when it made the account; false when there is one, with nothing written. The insert of the account is also
# refused by its primary key, and the transaction takes the write lock before the count, so a second first run waits
# and then finds the account.
def make_account(
  tx: Db.Connection,
  name: String,
  email: String,
  digest: String,
  token: String,
  user_agent: String,
) -> Result[Bool]
  exists = try account_exists?(tx)
  if exists
    return ok(false)
  end

  try Db.execute(
    tx,
    "insert into accounts (id, name, join_code) values (1, ?, ?)",
    [Db.Value.Text(ACCOUNT_NAME), Db.Value.Text(Accounts.new_join_code())],
  )

  users = try Db.query(
    tx,
    "insert into users (name, email, password_digest, role) values (?, ?, ?, ?) returning id",
    [Db.Value.Text(name), Db.Value.Text(email), Db.Value.Text(digest), Db.Value.Text(Rooms.ADMINISTRATOR)],
  )

  admin_id = int_of(users[0], "id")
  try Rooms.create_open_in(tx, admin_id, FIRST_ROOM_NAME)
  try insert_session(tx, admin_id, token, user_agent)
  return ok(true)
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
  user_agent: String,
) -> Result[JoinOutcome]
  valid = try Accounts.join_code_valid?(tx, code)
  if not valid
    return ok(JoinOutcome.Gone)
  end

  taken = try email_taken?(tx, email)
  if taken
    return ok(JoinOutcome.Invalid(EMAIL_TAKEN))
  end

  users = try Db.query(
    tx,
    "insert into users (name, email, password_digest) values (?, ?, ?) returning id",
    [Db.Value.Text(name), Db.Value.Text(email), Db.Value.Text(digest)],
  )

  user_id = int_of(users[0], "id")
  try Rooms.grant_open_rooms(tx, user_id)
  try insert_session(tx, user_id, token, user_agent)
  return ok(JoinOutcome.Joined(token))
end

def email_taken?(conn: Db.Connection, email: String) -> Result[Bool]
  rows = try Db.query(conn, "select count(*) as total from users where email = ?", [Db.Value.Text(email)])
  return ok(int_of(rows[0], "total") > 0)
end

# The address of the client is not here yet: the Bond pin has no `Conn.remote_addr`
# (agentica-lang/agentica-campfire#9).
def insert_session(conn: Db.Connection, user_id: Int, token: String, user_agent: String) -> Result[Int]
  return Db.execute(
    conn,
    "insert into sessions (user_id, token, user_agent) values (?, ?, ?)",
    [Db.Value.Int(user_id), Db.Value.Text(token), text_or_null(user_agent)],
  )
end

def text_or_null(text: String) -> Db.Value
  if text.empty?
    return Db.Value.Null
  end

  return Db.Value.Text(text)
end

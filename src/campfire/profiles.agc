## The profile of a person over the `users` table: what the page of a user shows (`UsersController#show`) and what a
## person saves of their own (`Users::ProfilesController#update`: name, email address, password and bio). These
## functions take an open connection and never see a request. The password is hashed by the caller before `save` takes
## the write lock, since hashing is slow.

import Db from "pkg/db/db"
import Auth from "auth"
import Passwords from "passwords"
import Rails from "repo/rails"
import {int_of, text_of} from "repo/rows"

## The longest name and bio, in characters (the bio's is the `maxlength` of Rails' form).
MAX_NAME_LENGTH = 100
MAX_BIO_LENGTH = 200
## What a profile form is told when a part of it does not do.
NAME_PROBLEM = "Enter your name"
CHALLENGE_PROBLEM = "Enter your current password to set a new one"
EMAIL_PROBLEM = "Enter a valid email address"
EMAIL_TAKEN = "An account with that email exists already"
BIO_PROBLEM = "The bio can have at most #{MAX_BIO_LENGTH} characters"

## A user as their page shows them. `email` is "" for a bot, which has none.
struct Detail
  id: Int
  name: String
  email: String
  bio: String
  role: String
  status: Int
  updated_at: String
end

## How a save ended: `Saved`, `Taken` when another account has the address by now, and `Gone` when the person is not
## active any more (nothing is written then).
enum Change
  Saved
  Taken
  Gone
end

## The user with this id in any status (Rails' `User.find`), or `none`.
def find(conn: Db.Connection, user_id: Int) -> Result[Optional[Detail]]
  rows = try Db.query(
    conn,
    "select id, name, coalesce(email_address, '') as email_address, coalesce(bio, '') as bio, role, status, " +
    "updated_at from users where id = ?",
    [Db.Value.Int(user_id)],
  )

  return ok(none) if rows.empty?

  row = rows[0]
  ok(
    some(
      Detail(
        id: int_of(row, "id"),
        name: text_of(row, "name"),
        email: text_of(row, "email_address"),
        bio: text_of(row, "bio"),
        role: Rails.role_name(int_of(row, "role")),
        status: int_of(row, "status"),
        updated_at: text_of(row, "updated_at"),
      ),
    ),
  )
end

## True for a user whose page says that they are no longer on the account.
def deactivated?(profile: Detail) -> Bool = profile.status == Rails.DEACTIVATED

## True for a user who can be written to: active.
def active?(profile: Detail) -> Bool = profile.status == Rails.ACTIVE

## What is wrong with a profile form, or "". A part that is `none` is not being changed. A blank email or password is
## not a change either (Rails ignores a blank password; a blank email would lock the person out, so it is ignored
## too). The address is looked for among the other accounts, in any case.
def problem(
  conn: Db.Connection,
  user_id: Int,
  name: Optional[String],
  email: Optional[String],
  password: Optional[String],
  bio: Optional[String],
) -> Result[String]
  return ok(NAME_PROBLEM) if name.some? and (name.unwrap!.strip.empty? or name.unwrap!.strip.length > MAX_NAME_LENGTH)

  return ok(BIO_PROBLEM) if bio.some? and bio.unwrap!.length > MAX_BIO_LENGTH

  if email.some? and not email.unwrap!.strip.empty?
    address = Auth.normal(email.unwrap!)
    return ok(EMAIL_PROBLEM) if not Auth.valid_email?(address)

    taken = try taken_by_other?(conn, address, user_id)
    return ok(EMAIL_TAKEN) if taken
  end

  return ok(Passwords.problem(password.unwrap!)) if password.some? and not password.unwrap!.empty?

  ok("")
end

## True when `current` is the password of the person (`password_challenge`). It hashes, so the caller holds a hashing
## slot. `bcrypt_library` is `CAMPFIRE_BCRYPT_LIBRARY`, for a digest that Rails made.
def challenge_ok?(conn: Db.Connection, user_id: Int, current: String, bcrypt_library: String) -> Result[Bool]
  return ok(false) if current.bytes.size > Passwords.MAX_BYTES

  rows = try Db.query(conn, "select password_digest from users where id = ?", [Db.Value.Int(user_id)])
  return ok(false) if rows.empty? or text_of(rows[0], "password_digest").empty?

  Passwords.verify(current, text_of(rows[0], "password_digest"), bcrypt_library)
end

## Saves the parts of the form that are not `none` for `user_id`, in one transaction that checks again that the person
## is active and that nobody took the address meanwhile. `digest` is the hash of the new password (`Passwords.hash`),
## `none` to keep the old one; a new digest also ends every session of the person but the one with the token
## `keep_token`, and deletes their push subscriptions (`sign_out_all_sessions` of Rails), so a stolen cookie or a
## forgotten browser stops working. A blank email is left as it is. A bio can be emptied.
def save(
  conn: Db.Connection,
  user_id: Int,
  name: Optional[String],
  email: Optional[String],
  digest: Optional[String],
  bio: Optional[String],
  keep_token: String,
) -> Result[Change]
  Db.transaction(conn) do |tx| save_in(tx, user_id, name, email, digest, bio, keep_token) end
end

private

NOW = Rails.NOW

def save_in(
  tx: Db.Connection,
  user_id: Int,
  name: Optional[String],
  email: Optional[String],
  digest: Optional[String],
  bio: Optional[String],
  keep_token: String,
) -> Result[Change]
  found = try Db.query(
    tx,
    "select 1 from users where id = ? and status = #{Rails.ACTIVE} and role <> #{Rails.BOT}",
    [Db.Value.Int(user_id)],
  )

  return ok(Change.Gone) if found.empty?

  if email.some? and not email.unwrap!.strip.empty?
    taken = try taken_by_other?(tx, Auth.normal(email.unwrap!), user_id)
    return ok(Change.Taken) if taken

    try set_column(tx, user_id, "email_address", Auth.normal(email.unwrap!))
  end

  if name.some?
    try set_column(tx, user_id, "name", name.unwrap!.strip)
  end

  if digest.some?
    try set_column(tx, user_id, "password_digest", digest.unwrap!)
    id = Db.Value.Int(user_id)
    try Db.execute(tx, "delete from sessions where user_id = ? and token <> ?", [id, Db.Value.Text(keep_token)])
    try Db.execute(tx, "delete from push_subscriptions where user_id = ?", [id])
  end

  if bio.some?
    try set_column(tx, user_id, "bio", bio.unwrap!.strip)
  end

  ok(Change.Saved)
end

# One column of the user, with `updated_at` touched: the avatar link of the profile and of the user page carries its
# digits as a cache buster (`Avatars.version`).
def set_column(tx: Db.Connection, user_id: Int, column: String, value: String) -> Result[Int]
  Db.execute(
    tx,
    "update users set #{column} = ?, updated_at = #{NOW} where id = ?",
    [Db.Value.Text(value), Db.Value.Int(user_id)],
  )
end

# True when a user other than `user_id` has the address, with or without capitals: the exact address first, which the
# unique index serves, and `lower(email_address)`, which scans `users`, only when no row has it
# (as `Auth.email_taken?`).
def taken_by_other?(conn: Db.Connection, address: String, user_id: Int) -> Result[Bool]
  exact = try Db.query(
    conn,
    "select 1 from users where email_address = ? and id <> ? limit 1",
    [Db.Value.Text(address), Db.Value.Int(user_id)],
  )

  return ok(true) if not exact.empty?

  rows = try Db.query(
    conn,
    "select 1 from users where lower(email_address) = ? and id <> ? limit 1",
    [Db.Value.Text(address), Db.Value.Int(user_id)],
  )

  ok(not rows.empty?)
end

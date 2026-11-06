## The profile of a person over the `users` table: what the page of a user shows (`UsersController#show`) and what a
## person saves of their own (`Users::ProfilesController#update`: name, email address, password and bio). These
## functions take an open connection and never see a request. The password is hashed by the caller before `save` takes
## the write lock, since hashing is slow.

import Db from "pkg/db/db"
import Auth from "auth"
import Passwords from "passwords"
import Rails from "repo/rails"
import {int_of, text_of} from "repo/rows"

NOW = Rails.NOW

## The longest name and bio, in characters (the bio's is the `maxlength` of Rails' form).
export MAX_NAME_LENGTH = 100
export MAX_BIO_LENGTH = 200

## What a profile form is told when a part of it does not do.
export NAME_PROBLEM = "Enter your name"
export EMAIL_PROBLEM = "Enter a valid email address"
export EMAIL_TAKEN = "An account with that email exists already"
export BIO_PROBLEM = "The bio can have at most #{MAX_BIO_LENGTH} characters"

## A user as their page shows them. `email` is "" for a bot, which has none.
export struct Detail
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
export enum Change
  Saved
  Taken
  Gone
end

## The user with this id in any status (Rails' `User.find`), or `none`.
export def find(conn: Db.Connection, user_id: Int) -> Result[Optional[Detail]]
  rows = try Db.query(
    conn,
    "select id, name, coalesce(email_address, '') as email_address, coalesce(bio, '') as bio, role, status, " +
    "updated_at from users where id = ?",
    [Db.Value.Int(user_id)],
  )

  if rows.empty?
    return ok(none)
  end

  row = rows[0]
  return ok(
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
export def deactivated?(profile: Detail) -> Bool
  return profile.status == Rails.DEACTIVATED
end

## True for a user who can be written to: active.
export def active?(profile: Detail) -> Bool
  return profile.status == Rails.ACTIVE
end

## What is wrong with a profile form, or "". A part that is `none` is not being changed. A blank email or password is
## not a change either (Rails ignores a blank password; a blank email would lock the person out, so it is ignored
## too). The address is looked for among the other accounts, in any case.
export def problem(
  conn: Db.Connection,
  user_id: Int,
  name: Optional[String],
  email: Optional[String],
  password: Optional[String],
  bio: Optional[String],
) -> Result[String]
  if name.some? and (name.unwrap!.strip.empty? or name.unwrap!.strip.length > MAX_NAME_LENGTH)
    return ok(NAME_PROBLEM)
  end

  if bio.some? and bio.unwrap!.length > MAX_BIO_LENGTH
    return ok(BIO_PROBLEM)
  end

  if email.some? and not email.unwrap!.strip.empty?
    address = Auth.normal(email.unwrap!)
    if not Auth.valid_email?(address)
      return ok(EMAIL_PROBLEM)
    end

    taken = try taken_by_other?(conn, address, user_id)
    if taken
      return ok(EMAIL_TAKEN)
    end
  end

  if password.some? and not password.unwrap!.empty?
    return ok(Passwords.problem(password.unwrap!))
  end

  return ok("")
end

## Saves the parts of the form that are not `none` for `user_id`, in one transaction that checks again that the person
## is active and that nobody took the address meanwhile. `digest` is the hash of the new password (`Passwords.hash`),
## `none` to keep the old one. A blank email is left as it is. A bio can be emptied.
export def save(
  conn: Db.Connection,
  user_id: Int,
  name: Optional[String],
  email: Optional[String],
  digest: Optional[String],
  bio: Optional[String],
) -> Result[Change]
  return Db.transaction(conn) do |tx| save_in(tx, user_id, name, email, digest, bio) end
end

def save_in(
  tx: Db.Connection,
  user_id: Int,
  name: Optional[String],
  email: Optional[String],
  digest: Optional[String],
  bio: Optional[String],
) -> Result[Change]
  found = try Db.query(
    tx,
    "select 1 from users where id = ? and status = #{Rails.ACTIVE} and role <> #{Rails.BOT}",
    [Db.Value.Int(user_id)],
  )

  if found.empty?
    return ok(Change.Gone)
  end

  if email.some? and not email.unwrap!.strip.empty?
    taken = try taken_by_other?(tx, Auth.normal(email.unwrap!), user_id)
    if taken
      return ok(Change.Taken)
    end

    try set_column(tx, user_id, "email_address", Auth.normal(email.unwrap!))
  end

  if name.some?
    try set_column(tx, user_id, "name", name.unwrap!.strip)
  end

  if digest.some?
    try set_column(tx, user_id, "password_digest", digest.unwrap!)
  end

  if bio.some?
    try set_column(tx, user_id, "bio", bio.unwrap!.strip)
  end

  return ok(Change.Saved)
end

# One column of the user, with `updated_at` touched: the avatar link of Rails' pages carries it as a cache buster.
def set_column(tx: Db.Connection, user_id: Int, column: String, value: String) -> Result[Int]
  return Db.execute(
    tx,
    "update users set #{column} = ?, updated_at = #{NOW} where id = ?",
    [Db.Value.Text(value), Db.Value.Int(user_id)],
  )
end

# True when a user other than `user_id` has the address, with or without capitals.
def taken_by_other?(conn: Db.Connection, address: String, user_id: Int) -> Result[Bool]
  rows = try Db.query(
    conn,
    "select 1 from users where id <> ? and (email_address = ? or lower(email_address) = ?) limit 1",
    [Db.Value.Int(user_id), Db.Value.Text(address), Db.Value.Text(address)],
  )

  return ok(not rows.empty?)
end

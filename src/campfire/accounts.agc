## The account over the `accounts` and `users` tables: its join code, and the people on it, who an administrator may
## deactivate and reactivate. These functions take an open connection and never see a request. A person is never
## deleted, only deactivated (the keys to `users` refuse a delete), so their messages stay. Each change runs in one
## write transaction that checks again that the person who asks is an active administrator, so a form that was allowed
## when its page was drawn is refused when the role has gone since, and two administrators who deactivate each other
## at the same time leave one of them standing: the second finds the first one inactive.

import Db from "pkg/db/db"
import Rooms from "rooms"
import Rails from "repo/rails"
import {int_of, text_of} from "repo/rows"

JOIN_CODE_BYTES = 6
GROUP = 4

# The code that the join page was asked for is a few characters; nothing longer is looked up.
MAX_CODE_LENGTH = 64

NOW = Rails.NOW

## A person of the account as the people page lists them. A bot is not a person, so it is never in the list.
export struct Person
  id: Int
  name: String
  email: String
  role: String
  active: Bool
end

## What a deactivation or reactivation did. `Unchanged` is a person who was in that state already (a double click).
## `Missing` is nobody that a person can be made of (no such user, or a bot). `Refused` is a person who asks without
## being an active administrator, or who deactivates themselves, which would leave an account without its way in.
export enum Change
  Changed
  Unchanged
  Missing
  Refused
end

## Three groups of four hex digits, `a1b2-c3d4-e5f6`, to type or read out.
export def new_join_code() -> String
  digits = SecureRandom.hex(JOIN_CODE_BYTES)
  return "#{digits.slice(0, GROUP)}-#{digits.slice(GROUP, GROUP)}-#{digits.slice(GROUP * 2, GROUP)}"
end

## The join code of the account, or "" before the first run has made it.
export def join_code(conn: Db.Connection) -> Result[String]
  rows = try Db.query(conn, "select join_code from accounts order by id limit 1", [])
  if rows.empty?
    return ok("")
  end

  return ok(text_of(rows[0], "join_code"))
end

## True when `code` is the code of the account now: the old code of a regenerated one is not.
export def join_code_valid?(conn: Db.Connection, code: String) -> Result[Bool]
  if code.empty? or code.length > MAX_CODE_LENGTH
    return ok(false)
  end

  rows = try Db.query(conn, "select count(*) as total from accounts where join_code = ?", [Db.Value.Text(code)])
  return ok(int_of(rows[0], "total") > 0)
end

## Makes a new join code, which ends the link of the old one, and gives true. It gives false, with nothing changed,
## when `actor_id` is not an active administrator.
export def regenerate_join_code(conn: Db.Connection, actor_id: Int) -> Result[Bool]
  return Db.transaction(conn) do |tx| regenerate_in(tx, actor_id) end
end

## The people of the account by name: the active ones, or with `everyone` the deactivated ones too, for the
## administrator who may bring them back.
export def people(conn: Db.Connection, everyone: Bool) -> Result[List[Person]]
  # A banned person is not in the list: banning is not something the app does yet, and the people page has no way back
  # from it.
  shown = "status = #{Rails.ACTIVE}"
  if everyone
    shown = "status in (#{Rails.ACTIVE}, #{Rails.DEACTIVATED})"
  end

  sql = "select id, name, email_address, role, status from users where role <> #{Rails.BOT} and #{shown}"
  rows = try Db.query(conn, "#{sql} order by lower(name), id", [])
  return ok(
    rows.map do |row|
      Person(
        id: int_of(row, "id"),
        name: text_of(row, "name"),
        email: text_of(row, "email_address"),
        role: Rails.role_name(int_of(row, "role")),
        active: int_of(row, "status") == Rails.ACTIVE,
      )
    end,
  )
end

## Deactivates `user_id` for `actor_id`: they cannot sign in, and every session of theirs and every password reset
## link ends in the same transaction. Their rooms and messages stay as they are.
export def deactivate(conn: Db.Connection, actor_id: Int, user_id: Int) -> Result[Change]
  return Db.transaction(conn) do |tx| deactivate_in(tx, actor_id, user_id) end
end

## Reactivates `user_id` for `actor_id` and puts them in the open rooms that were made while they were away
## (`Rooms.grant_open_rooms`), in the same transaction.
export def reactivate(conn: Db.Connection, actor_id: Int, user_id: Int) -> Result[Change]
  return Db.transaction(conn) do |tx| reactivate_in(tx, actor_id, user_id) end
end

def regenerate_in(tx: Db.Connection, actor_id: Int) -> Result[Bool]
  allowed = try administrator?(tx, actor_id)
  if not allowed
    return ok(false)
  end

  try Db.execute(
    tx,
    "update accounts set join_code = ?, updated_at = #{NOW} where singleton_guard = 0",
    [Db.Value.Text(new_join_code())],
  )

  return ok(true)
end

def deactivate_in(tx: Db.Connection, actor_id: Int, user_id: Int) -> Result[Change]
  allowed = try administrator?(tx, actor_id)
  if not allowed or actor_id == user_id
    return ok(Change.Refused)
  end

  changed = try Db.execute(
    tx,
    "update users set status = #{Rails.DEACTIVATED}, updated_at = #{NOW} where id = ? and " +
    "status = #{Rails.ACTIVE} and role <> #{Rails.BOT}",
    [Db.Value.Int(user_id)],
  )

  if changed == 0
    return unchanged_or_missing(tx, user_id)
  end

  try Db.execute(tx, "delete from sessions where user_id = ?", [Db.Value.Int(user_id)])
  try Db.execute(tx, "delete from password_resets where user_id = ?", [Db.Value.Int(user_id)])
  return ok(Change.Changed)
end

def reactivate_in(tx: Db.Connection, actor_id: Int, user_id: Int) -> Result[Change]
  allowed = try administrator?(tx, actor_id)
  if not allowed
    return ok(Change.Refused)
  end

  changed = try Db.execute(
    tx,
    "update users set status = #{Rails.ACTIVE}, updated_at = #{NOW} where id = ? and " +
    "status = #{Rails.DEACTIVATED} and role <> #{Rails.BOT}",
    [Db.Value.Int(user_id)],
  )

  if changed == 0
    return unchanged_or_missing(tx, user_id)
  end

  try Rooms.grant_open_rooms(tx, user_id)
  return ok(Change.Changed)
end

# An update that changed nothing is a person who was in the state already, or nobody.
def unchanged_or_missing(tx: Db.Connection, user_id: Int) -> Result[Change]
  rows = try Db.query(
    tx,
    "select count(*) as total from users where id = ? and role <> #{Rails.BOT}",
    [Db.Value.Int(user_id)],
  )

  if int_of(rows[0], "total") > 0
    return ok(Change.Unchanged)
  end

  return ok(Change.Missing)
end

def administrator?(tx: Db.Connection, user_id: Int) -> Result[Bool]
  rows = try Db.query(
    tx,
    "select count(*) as total from users where id = ? and role = ? and status = #{Rails.ACTIVE}",
    [Db.Value.Int(user_id), Db.Value.Int(Rails.ADMINISTRATOR)],
  )

  return ok(int_of(rows[0], "total") > 0)
end

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

# What a deactivation puts in the address, between the name and the `@` (`deactived_email_address` of Rails).
MARKER = "-deactivated-"
UUID_LENGTH = 36

## The longest name of the account, in characters.
export MAX_NAME_LENGTH = 100

# The key of the setting in the JSON of `accounts.settings`, the one Rails writes.
RESTRICT_KEY = "restrict_room_creation_to_administrators"

## A person of the account as the people page lists them. A bot is not a person, so it is never in the list. A person
## who is neither `active` nor `banned` is deactivated.
export struct Person
  id: Int
  name: String
  email: String
  role: String
  active: Bool
  banned: Bool
end

## What a deactivation or reactivation did. `Unchanged` is a person who was in that state already (a double click).
## `Missing` is nobody that a person can be made of (no such user, or a bot). `Refused` is a person who asks without
## being an active administrator, or who deactivates themselves, which would leave an account without its way in.
## `Taken` is a reactivation of a person whose address is another account's now: the address that a deactivation
## frees (see `deactivate`) can be used to join again, and one address is one account.
export enum Change
  Changed
  Unchanged
  Missing
  Refused
  Taken
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

## The name of the account, or "" before the first run has made it.
export def name(conn: Db.Connection) -> Result[String]
  rows = try Db.query(conn, "select name from accounts order by id limit 1", [])
  if rows.empty?
    return ok("")
  end

  return ok(text_of(rows[0], "name"))
end

## What is wrong with an account name, or "". The caller strips it first. Rails has no check (the column only refuses
## null); a blank name would leave the page with nothing to show, so it is refused here.
export def name_problem(name: String) -> String
  if name.empty? or name.length > MAX_NAME_LENGTH
    return "Give the account a name of 1 to #{MAX_NAME_LENGTH} characters"
  end

  return ""
end

## Saves what `AccountsController#update` takes of the form, in one transaction: the `name`, and whether only
## administrators `restricted` the creation of rooms (the setting `restrict_room_creation_to_administrators`, which Rails
## keeps in the JSON of `accounts.settings`; the other keys of that JSON stay as they are). A part that is `none` is left
## alone. It gives false, with nothing changed, when `actor_id` is not an active administrator.
export def save(conn: Db.Connection, actor_id: Int, name: Optional[String], restricted: Optional[Bool]) -> Result[Bool]
  return Db.transaction(conn) do |tx| save_in(tx, actor_id, name, restricted) end
end

## True when the account lets only administrators make a shared room (open or closed): `Rooms::OpensController` and
## `ClosedsController` answer 403 to anyone else. A direct message is not a room in that sense and is not restricted, as
## in Rails. Only a real true (or the text `true`) restricts: a `settings` that is empty, is not JSON, or holds any other
## value under the key (a string `"false"`, `0.0`, an object) is the default, not restricted.
export def room_creation_restricted?(conn: Db.Connection) -> Result[Bool]
  rows = try Db.query(
    conn,
    "select case when json_valid(settings) then " +
    "coalesce(json_extract(settings, '$.#{RESTRICT_KEY}') in (1, 'true'), 0) else 0 end " +
    "as restricted from accounts order by id limit 1",
    [],
  )

  if rows.empty?
    return ok(false)
  end

  return ok(int_of(rows[0], "restricted") != 0)
end

## True when `user_id` is an active person of the account (not a bot), whom the role and the removal can name.
export def active_person?(conn: Db.Connection, user_id: Int) -> Result[Bool]
  rows = try Db.query(
    conn,
    "select count(*) as total from users where id = ? and status = #{Rails.ACTIVE} and role <> #{Rails.BOT}",
    [Db.Value.Int(user_id)],
  )

  return ok(int_of(rows[0], "total") > 0)
end

## Makes `user_id` an administrator, or a member with `administrator` false (`Accounts::UsersController#update`), for
## `actor_id`. `Missing` is nobody active (a deactivated person, a bot, no such user). `Refused` is a person who asks
## without being an active administrator, or who changes their own role: the page has no switch for oneself, and an
## administrator who steps down alone could leave the account without one. Rails does not check either on the server;
## here the actor stays an administrator, so the account always has one.
export def set_role(conn: Db.Connection, actor_id: Int, user_id: Int, administrator: Bool) -> Result[Change]
  return Db.transaction(conn) do |tx| set_role_in(tx, actor_id, user_id, administrator) end
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

## The people of the account by name: the active ones, or with `everyone` the deactivated and banned ones too, for the
## administrator who may bring them back or lift the ban.
export def people(conn: Db.Connection, everyone: Bool) -> Result[List[Person]]
  shown = "status = #{Rails.ACTIVE}"
  if everyone
    shown = "status in (#{Rails.ACTIVE}, #{Rails.DEACTIVATED}, #{Rails.BANNED})"
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
        banned: int_of(row, "status") == Rails.BANNED,
      )
    end,
  )
end

## Deactivates `user_id` for `actor_id` as Rails' `User#deactivate` does, in one transaction: they cannot sign in; every
## session, password reset link, push subscription and search of theirs is deleted; they leave every room but the
## direct messages (the memberships of the open and closed rooms are deleted); and their address becomes
## `name-deactivated-UUID@domain`, which frees it for a new account. Their messages, and the rooms they made, stay.
export def deactivate(conn: Db.Connection, actor_id: Int, user_id: Int) -> Result[Change]
  return Db.transaction(conn) do |tx| deactivate_in(tx, actor_id, user_id) end
end

## Reactivates `user_id` for `actor_id`, in one transaction: they get their address back and every open room that exists
## (`Rooms.grant_open_rooms`, as a new person does). The closed rooms they left are not given back, as Rails has no way
## back at all. `Taken` when the address is another account's now, with nothing changed. A person who was deactivated
## before the address was renamed keeps the address they have.
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

def save_in(tx: Db.Connection, actor_id: Int, name: Optional[String], restricted: Optional[Bool]) -> Result[Bool]
  allowed = try administrator?(tx, actor_id)
  if not allowed
    return ok(false)
  end

  if name.some?
    try Db.execute(
      tx,
      "update accounts set name = ?, updated_at = #{NOW} where singleton_guard = 0",
      [Db.Value.Text(name.unwrap!)],
    )
  end

  if restricted.some?
    flag = "false"
    if restricted.unwrap!
      flag = "true"
    end

    # `json(?)` makes the text a JSON boolean, not a string; the other keys of the settings are kept. Settings that are
    # not a JSON object (`[1]`, `null`, `5`, not JSON) would stay unchanged under `json_set`, so they start over
    # as `{}`.
    try Db.execute(
      tx,
      "update accounts set settings = json_set(case when json_valid(settings) then " +
      "case when json_type(settings) = 'object' then settings else '{}' end else '{}' end, " +
      "'$.#{RESTRICT_KEY}', json(?)), updated_at = #{NOW} where singleton_guard = 0",
      [Db.Value.Text(flag)],
    )
  end

  return ok(true)
end

def set_role_in(tx: Db.Connection, actor_id: Int, user_id: Int, administrator: Bool) -> Result[Change]
  allowed = try administrator?(tx, actor_id)
  if not allowed or actor_id == user_id
    return ok(Change.Refused)
  end

  role = Rails.MEMBER
  if administrator
    role = Rails.ADMINISTRATOR
  end

  changed = try Db.execute(
    tx,
    "update users set role = ?, updated_at = #{NOW} where id = ? and status = #{Rails.ACTIVE} and role <> #{Rails.BOT}",
    [Db.Value.Int(role), Db.Value.Int(user_id)],
  )

  if changed == 0
    return ok(Change.Missing)
  end

  return ok(Change.Changed)
end

def deactivate_in(tx: Db.Connection, actor_id: Int, user_id: Int) -> Result[Change]
  allowed = try administrator?(tx, actor_id)
  if not allowed or actor_id == user_id
    return ok(Change.Refused)
  end

  # The text before the `@` and the text from it are kept and the marker goes between them, as Rails' `gsub(/@/, ...)`
  # does; an address with no `@` (a bot has none, and is not here) is left as it is.
  changed = try Db.execute(
    tx,
    "update users set status = #{Rails.DEACTIVATED}, updated_at = #{NOW}, " +
    "email_address = case when instr(email_address, '@') > 0 then " +
    "substr(email_address, 1, instr(email_address, '@') - 1) || '#{MARKER}' || ? || " +
    "substr(email_address, instr(email_address, '@')) else email_address end " +
    "where id = ? and status = #{Rails.ACTIVE} and role <> #{Rails.BOT}",
    [Db.Value.Text(SecureRandom.uuid()), Db.Value.Int(user_id)],
  )

  if changed == 0
    return unchanged_or_missing(tx, user_id)
  end

  id = Db.Value.Int(user_id)
  try Db.execute(tx, "delete from sessions where user_id = ?", [id])
  try Db.execute(tx, "delete from password_resets where user_id = ?", [id])
  try Db.execute(tx, "delete from push_subscriptions where user_id = ?", [id])
  try Db.execute(tx, "delete from searches where user_id = ?", [id])
  try Rooms.leave_shared_rooms(tx, user_id)
  return ok(Change.Changed)
end

def reactivate_in(tx: Db.Connection, actor_id: Int, user_id: Int) -> Result[Change]
  allowed = try administrator?(tx, actor_id)
  if not allowed
    return ok(Change.Refused)
  end

  # The address before the deactivation, which `original_address` finds in the stored one.
  rows = try Db.query(
    tx,
    "select email_address from users where id = ? and status = #{Rails.DEACTIVATED} and role <> #{Rails.BOT}",
    [Db.Value.Int(user_id)],
  )

  if rows.empty?
    return unchanged_or_missing(tx, user_id)
  end

  original = original_address(text_of(rows[0], "email_address"))
  taken = try Db.query(
    tx,
    "select count(*) as total from users where id <> ? and lower(email_address) = lower(?)",
    [Db.Value.Int(user_id), Db.Value.Text(original)],
  )

  if int_of(taken[0], "total") > 0
    return ok(Change.Taken)
  end

  try Db.execute(
    tx,
    "update users set status = #{Rails.ACTIVE}, email_address = ?, updated_at = #{NOW} where id = ?",
    [Db.Value.Text(original), Db.Value.Int(user_id)],
  )

  try Rooms.grant_open_rooms(tx, user_id)
  return ok(Change.Changed)
end

# The address before a deactivation of this app or of Rails: the marker and a UUID (8-4-4-4-12 hex digits) right before
# the one `@`, taken away. Anything else is its own address: one that has the marker without the UUID, or in the
# domain, was typed that way by its owner (or deactivated before the rename) and must not be changed.
def original_address(address: String) -> String
  parts = address.split("@")
  if parts.size != 2
    return address
  end

  local = parts[0]
  tail = MARKER.length + UUID_LENGTH
  if local.length <= tail
    return address
  end

  cut = local.length - tail
  if local.slice(cut, MARKER.length) != MARKER or not uuid_shape?(local.slice(cut + MARKER.length, UUID_LENGTH))
    return address
  end

  return "#{local.slice(0, cut)}@#{parts[1]}"
end

def uuid_shape?(text: String) -> Bool
  if text.length != UUID_LENGTH
    return false
  end

  for index in 0..(UUID_LENGTH - 1)
    digit = text.slice(index, 1)
    if index == 8 or index == 13 or index == 18 or index == 23
      if digit != "-"
        return false
      end
    elsif not "0123456789abcdef".include?(digit)
      return false
    end
  end

  return true
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

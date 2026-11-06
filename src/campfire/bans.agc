## Bans over the `bans` and `users` tables (`User::Bannable` and `Ban` of Rails): an administrator bans a person, which
## ends their sessions, writes one ban for each public address their sessions came from, and takes their messages away;
## a request that changes something and comes from a banned address is refused. These functions take an open connection
## and never see a request. Both changes check again, inside their transaction, that the actor is an active
## administrator and not the person, so the account always keeps one.

import Db from "pkg/db/db"
import Accounts from "accounts"
import Rooms from "rooms"
import Rails from "repo/rails"
import {int_of, text_of} from "repo/rows"

NOW = Rails.NOW

## A message that `delete_next_message` took away: where it was, so that the caller can tell the people in the room.
export struct Gone
  room_id: Int
  message_id: Int
end

## True when a ban holds the address (`Ban.banned?`).
export def banned?(conn: Db.Connection, address: String) -> Result[Bool]
  rows = try Db.query(conn, "select 1 from bans where ip_address = ? limit 1", [Db.Value.Text(address)])
  return ok(not rows.empty?)
end

## Bans `user_id` for `actor_id`: one ban for each distinct public address of their sessions (Rails refuses a private,
## loopback or link-local address with an error that undoes the whole ban; here such an address is left out, since a
## ban of it would lock out everyone behind it), then `status` banned and no session left. `Missing` is nobody active
## (no such user, a bot, a person who is deactivated); a person who is banned already is `Unchanged`. `Refused` is an
## actor who is not an active administrator, or who bans themselves.
export def ban(conn: Db.Connection, actor_id: Int, user_id: Int) -> Result[Accounts.Change]
  return Db.transaction(conn) do |tx| ban_in(tx, actor_id, user_id) end
end

## Lifts the ban of `user_id`: the bans go and the person is active again, as before. A person who is active already
## is `Unchanged`; `Missing` and `Refused` are as for `ban`.
export def unban(conn: Db.Connection, actor_id: Int, user_id: Int) -> Result[Accounts.Change]
  return Db.transaction(conn) do |tx| unban_in(tx, actor_id, user_id) end
end

## Deletes one message that `user_id` wrote, with its body, its search row and its boosts, in a transaction of its own
## (the content of a banned person can be long, and the other writers get through between two messages). It gives
## where the message was, or `none` when the person has none left.
export def delete_next_message(conn: Db.Connection, user_id: Int) -> Result[Optional[Gone]]
  return Db.transaction(conn) do |tx| delete_first_message(tx, user_id) end
end

## True for a public address, one that a ban may hold: an IPv4 address that is not loopback (127/8), private (10/8,
## 172.16/12, 192.168/16) or link-local (169.254/16), or an IPv6 one that is not loopback, unique local (fc00::/7) or
## link-local (fe80::/10). An address that is neither is not one (`Ban#ip_address_is_public`).
export def public_address?(address: String) -> Bool
  text = address.downcase
  if text.start_with?("::ffff:") and text.include?(".")
    return public_v4?(text.slice(7, text.length - 7))
  end

  if text.include?(":")
    return public_v6?(text)
  end

  return public_v4?(text)
end

def ban_in(tx: Db.Connection, actor_id: Int, user_id: Int) -> Result[Accounts.Change]
  if not try administrator?(tx, actor_id) or actor_id == user_id
    return ok(Accounts.Change.Refused)
  end

  status = try status_of(tx, user_id)
  if status.none? or status.unwrap! != Rails.ACTIVE and status.unwrap! != Rails.BANNED
    return ok(Accounts.Change.Missing)
  end

  if status.unwrap! == Rails.BANNED
    return ok(Accounts.Change.Unchanged)
  end

  id = Db.Value.Int(user_id)
  addresses = try Db.query(
    tx,
    "select distinct ip_address from sessions where user_id = ? and ip_address is not null and ip_address <> ''",
    [id],
  )

  for row in addresses
    address = text_of(row, "ip_address")
    if public_address?(address)
      try Db.execute(
        tx,
        "insert into bans (ip_address, user_id, created_at, updated_at) select ?, ?, #{NOW}, #{NOW} " +
        "where not exists (select 1 from bans where user_id = ? and ip_address = ?)",
        [Db.Value.Text(address), id, id, Db.Value.Text(address)],
      )
    end
  end

  try Db.execute(tx, "delete from sessions where user_id = ?", [id])
  try Db.execute(tx, "delete from password_resets where user_id = ?", [id])
  try Db.execute(tx, "update users set status = #{Rails.BANNED}, updated_at = #{NOW} where id = ?", [id])
  return ok(Accounts.Change.Changed)
end

def unban_in(tx: Db.Connection, actor_id: Int, user_id: Int) -> Result[Accounts.Change]
  if not try administrator?(tx, actor_id) or actor_id == user_id
    return ok(Accounts.Change.Refused)
  end

  status = try status_of(tx, user_id)
  if status.none? or status.unwrap! != Rails.ACTIVE and status.unwrap! != Rails.BANNED
    return ok(Accounts.Change.Missing)
  end

  if status.unwrap! == Rails.ACTIVE
    return ok(Accounts.Change.Unchanged)
  end

  id = Db.Value.Int(user_id)
  try Db.execute(tx, "delete from bans where user_id = ?", [id])
  try Db.execute(tx, "update users set status = #{Rails.ACTIVE}, updated_at = #{NOW} where id = ?", [id])
  return ok(Accounts.Change.Changed)
end

# The status of a person who is not a bot, or `none`.
def status_of(tx: Db.Connection, user_id: Int) -> Result[Optional[Int]]
  rows = try Db.query(
    tx,
    "select status from users where id = ? and role <> #{Rails.BOT}",
    [Db.Value.Int(user_id)],
  )

  if rows.empty?
    return ok(none)
  end

  return ok(some(int_of(rows[0], "status")))
end

def administrator?(tx: Db.Connection, user_id: Int) -> Result[Bool]
  rows = try Db.query(
    tx,
    "select count(*) as total from users where id = ? and role = ? and status = #{Rails.ACTIVE}",
    [Db.Value.Int(user_id), Db.Value.Int(Rails.ADMINISTRATOR)],
  )

  return ok(int_of(rows[0], "total") > 0)
end

def delete_first_message(tx: Db.Connection, user_id: Int) -> Result[Optional[Gone]]
  rows = try Db.query(
    tx,
    "select id, room_id from messages where creator_id = ? order by id limit 1",
    [Db.Value.Int(user_id)],
  )

  if rows.empty?
    return ok(none)
  end

  message_id = int_of(rows[0], "id")
  try Rooms.delete_message_rows_of(tx, message_id)
  return ok(some(Gone(room_id: int_of(rows[0], "room_id"), message_id: message_id)))
end

# Four numbers from 0 to 255 that are not in a range of local use.
def public_v4?(text: String) -> Bool
  parts = text.split(".")
  if parts.size != 4
    return false
  end

  numbers: List[Int] = []
  for part in parts
    parsed = part.to_i
    if part.empty? or part.length > 3 or not parsed.ok? or parsed.unwrap! > 255 or parsed.unwrap! < 0
      return false
    end

    numbers = numbers.push(parsed.unwrap!)
  end

  first = numbers[0]
  second = numbers[1]
  local = (
    first == 127 or
    first == 10 or
    (first == 172 and second >= 16 and second <= 31) or
    (first == 192 and second == 168) or
    (first == 169 and second == 254)
  )

  return not local
end

# Hex groups and colons, and not `::1`, `fc00::/7` or `fe80::/10`.
def public_v6?(text: String) -> Bool
  for index in 0..text.length - 1
    if not "0123456789abcdef:".include?(text.slice(index, 1))
      return false
    end
  end

  if text == "::1" or text == "::" or text.start_with?("fc") or text.start_with?("fd")
    return false
  end

  link_local = text.start_with?("fe8") or text.start_with?("fe9") or text.start_with?("fea") or text.start_with?("feb")
  complete = text.include?("::") or text.split(":").size == 8
  return complete and not link_local
end

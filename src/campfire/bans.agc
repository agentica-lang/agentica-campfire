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

## True when the table holds a ban at all.
export def any?(conn: Db.Connection) -> Result[Bool]
  rows = try Db.query(conn, "select 1 from bans limit 1", [])
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
## where the message was, or `none` when the person has none left or is not banned any more: a ban that was lifted
## ends the task, so what the person writes after they sign in again stays.
export def delete_next_message(conn: Db.Connection, user_id: Int) -> Result[Optional[Gone]]
  return Db.transaction(conn) do |tx| delete_first_message(tx, user_id) end
end

## True for an address that a ban may hold. This is stricter than Rails, which refuses only loopback, private (RFC 1918
## and unique local) and link-local addresses, and it has to be: the app bans the raw peer of the connection, not
## `remote_ip`, so behind a reverse proxy every request has the proxy's address, and a ban of it would answer 429 to
## every write of everybody, the sign-in included. A proxy is usually on a loopback, private, shared (100.64.0.0/10,
## which Tailscale and carrier networks use) or documentation address, so none of these is held, nor are the other
## ranges that are not the open internet: 0.0.0.0/8, 192.0.0.0/24, 198.18.0.0/15, and multicast and reserved
## (224.0.0.0/3). An IPv6 address is held only inside `2000::/3`, and not in `2001:db8::/32`, `2001:2::/48` or
## `3fff::/20`. An IPv4-mapped address (`::ffff:a.b.c.d` or `::ffff:xxxx:xxxx`) is judged as the IPv4 address it holds.
export def public_address?(address: String) -> Bool
  text = address.downcase
  if text.start_with?("::ffff:")
    return public_mapped?(text.slice(7, text.length - 7))
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
  if status.none? or (status.unwrap! != Rails.ACTIVE and status.unwrap! != Rails.BANNED)
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
  if status.none? or (status.unwrap! != Rails.ACTIVE and status.unwrap! != Rails.BANNED)
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
  rows = try Db.query(tx, "select status from users where id = ? and role <> #{Rails.BOT}", [Db.Value.Int(user_id)])

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
    "select messages.id, messages.room_id from messages join users on users.id = messages.creator_id " +
    "where messages.creator_id = ? and users.status = #{Rails.BANNED} order by messages.id limit 1",
    [Db.Value.Int(user_id)],
  )

  if rows.empty?
    return ok(none)
  end

  message_id = int_of(rows[0], "id")
  try Rooms.delete_message_rows_of(tx, message_id)
  return ok(some(Gone(room_id: int_of(rows[0], "room_id"), message_id: message_id)))
end

# The rest of `::ffff:`: dotted, or two hex groups of 16 bits.
def public_mapped?(rest: String) -> Bool
  if rest.include?(".")
    return public_v4?(rest)
  end

  groups = rest.split(":")
  if groups.size != 2
    return false
  end

  high = hex_value(groups[0])
  low = hex_value(groups[1])
  if high.none? or low.none?
    return false
  end

  return public_octets?(high.unwrap! / 256, high.unwrap! % 256, low.unwrap! / 256)
end

# The value of 1 to 4 hex digits, or `none`.
def hex_value(text: String) -> Optional[Int]
  digits = "0123456789abcdef"
  if text.empty? or text.length > 4
    return none
  end

  value = 0
  for index in 0..(text.length - 1)
    found = -1
    for digit in 0..15
      if digits.slice(digit, 1) == text.slice(index, 1)
        found = digit
      end
    end

    if found < 0
      return none
    end

    value = value * 16 + found
  end

  return some(value)
end

# Four numbers from 0 to 255 that are in public space.
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

  return public_octets?(numbers[0], numbers[1], numbers[2])
end

# True when the first three octets of an IPv4 address are in none of the ranges that are not the open internet.
def public_octets?(first: Int, second: Int, third: Int) -> Bool
  local = (
    first == 0 or
    first == 10 or
    first == 127 or
    first >= 224 or
    (first == 100 and second >= 64 and second <= 127) or
    (first == 169 and second == 254) or
    (first == 172 and second >= 16 and second <= 31) or
    (first == 192 and second == 0 and (third == 0 or third == 2)) or
    (first == 192 and second == 168) or
    (first == 198 and (second == 18 or second == 19)) or
    (first == 198 and second == 51 and third == 100) or
    (first == 203 and second == 0 and third == 113)
  )

  return not local
end

# An allowlist: only the global unicast space `2000::/3` can be public, and in it not the documentation prefix
# `2001:db8::/32`, the benchmarking prefix `2001:2::/48` and the reserved `3fff::/20`. Everything else is a special
# address (`::`, `::1`, unique local, link-local, multicast...) or not allocated yet.
def public_v6?(text: String) -> Bool
  for index in 0..(text.length - 1)
    if not "0123456789abcdef:".include?(text.slice(index, 1))
      return false
    end
  end

  groups = text.split(":")
  if not (text.include?("::") or groups.size == 8) or groups.empty?
    return false
  end

  first = hex_value(groups[0])
  if first.none? or first.unwrap! < 8192 or first.unwrap! > 16383
    return false
  end

  second = group_value(groups, 1)
  third = group_value(groups, 2)
  documentation = first.unwrap! == 8193 and second == 3512
  benchmarking = first.unwrap! == 8193 and second == 2 and third == 0
  reserved = first.unwrap! == 16383 and second < 4096
  return second >= 0 and not documentation and not benchmarking and not reserved
end

# The value of the group `index`: 0 for one that `::` leaves empty or that is not there, -1 for one that is no number.
def group_value(groups: List[String], index: Int) -> Int
  if index >= groups.size or groups[index].empty?
    return 0
  end

  value = hex_value(groups[index])
  if value.none?
    return -1
  end

  return value.unwrap!
end

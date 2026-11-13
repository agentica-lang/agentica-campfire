## Who is connected to which room, kept in memory: the people whose page of a room has its `PresenceChannel` open. It
## is the `connections` and `connected_at` of a membership in Rails (`Membership::Connectable`), without the database
## writes: a page that refreshes every 50 s would write a row each time. A person is connected for
## `Rails.CONNECTION_TTL_SECONDS` after the last `present` or `refresh`, so a tab that vanished (a closed laptop) stops
## counting by itself, and a second tab keeps the person connected while any of them is open.
##
## The two tables are updated one after the other, not in one step: two tabs that come at the same instant may count
## one less, which the next `refresh` of either repairs. The clock is an argument (Unix milliseconds), so a test can
## move it.

import Rails from "repo/rails"

## How long a person stays connected without a `refresh`.
TTL_MS = Rails.CONNECTION_TTL_SECONDS * 1000

## The tabs of each person in each room (`connections`), when each last said it was there (`connected_at`) and which
## connections of the cable are counted in `connections` (`held`, one entry for each room, person and connection).
struct Presence
  connections: ATS[String, Int]
  connected_at: ATS[String, Int]
  held: ATS[String, Int]
end

## An empty table.
def new() -> Presence
  connections: ATS[String, Int] = ATS.new()
  connected_at: ATS[String, Int] = ATS.new()
  held: ATS[String, Int] = ATS.new()
  Presence(connections: connections, connected_at: connected_at, held: held)
end

## A tab of the person opened the room page: one more connection, or the first one when the person was not connected.
## `connection` is the cable connection of the tab: a repeat of `present` on the same one only refreshes, so the
## count is the number of tabs however often a tab says it is there. A connection runs its handlers one at a time,
## so the check and the count cannot race.
def present(presence: Presence, room_id: Int, user_id: Int, connection: Int, now_ms: Int) -> Void
  key = key_of(room_id, user_id)
  held = held_key(room_id, user_id, connection)
  if presence.held.has_key?(held)
    refresh_counted(presence, key, room_id, user_id, now_ms)
    return
  end

  presence.held.put(held, 1)
  if connected?(presence, room_id, user_id, now_ms)
    presence.connections.add(key, 1)
  else
    presence.connections.put(key, 1)
  end

  presence.connected_at.put(key, now_ms)
end

## A tab closed: one connection less, and the person is not connected when none is left. A connection that is not
## counted (it never said it was there, or already left) changes nothing, so a repeat cannot take away another tab.
def absent(presence: Presence, room_id: Int, user_id: Int, connection: Int, now_ms: Int) -> Void
  held = held_key(room_id, user_id, connection)
  return if not presence.held.has_key?(held)

  presence.held.delete(held)
  key = key_of(room_id, user_id)
  return if not presence.connections.has_key?(key)

  left = 0
  if connected?(presence, room_id, user_id, now_ms)
    left = presence.connections.add(key, -1)
  end

  if left < 1
    presence.connections.delete(key)
    presence.connected_at.delete(key)
  end
end

## A tab says it is still there: the person stays connected for another `TTL_MS`. A tab that was not counted yet is
## counted (`present`); a person whose time had run out is connected again with one connection.
def refresh(presence: Presence, room_id: Int, user_id: Int, connection: Int, now_ms: Int) -> Void
  present(presence, room_id, user_id, connection, now_ms)
end

## True when the person was last seen in the room less than `TTL_MS` ago.
def connected?(presence: Presence, room_id: Int, user_id: Int, now_ms: Int) -> Bool
  seen = presence.connected_at.get(key_of(room_id, user_id))
  seen.ok? and now_ms - seen.unwrap! < TTL_MS
end

## How many tabs of the person are in the room, 0 when they are not connected.
def tabs(presence: Presence, room_id: Int, user_id: Int, now_ms: Int) -> Int
  return 0 if not connected?(presence, room_id, user_id, now_ms)

  presence.connections.get(key_of(room_id, user_id)).unwrap_or(0)
end

private

# A counted tab that refreshes: the time moves, and a person whose time had run out has this tab only.
def refresh_counted(presence: Presence, key: String, room_id: Int, user_id: Int, now_ms: Int) -> Void
  if not connected?(presence, room_id, user_id, now_ms)
    presence.connections.put(key, 1)
  end

  presence.connected_at.put(key, now_ms)
end

def key_of(room_id: Int, user_id: Int) -> String = "#{room_id}:#{user_id}"

def held_key(room_id: Int, user_id: Int, connection: Int) -> String = "#{room_id}:#{user_id}:#{connection}"

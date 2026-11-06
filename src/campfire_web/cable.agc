## The live side of the app: `/cable`, the Action Cable WebSocket of the Rails clients and of the benchmark, on
## `bond-channels`. The pages carry `<turbo-cable-stream-source>` elements with signed stream names; a client opens
## `/cable` with its session cookie, subscribes to what the page names, and hears what the routes broadcast.
##
## Streams (the names are ours: a client only ever holds them signed):
## - `room:ID:messages`: a new message of a room, as the Turbo Stream that appends it. `RoomMessagesChannel` checks
##   the membership when the subscription is made, so a name that a person kept after leaving a room streams nothing.
## - `rooms` and `user:ID:rooms`: the rooms that are made or renamed, as Turbo Streams for the sidebar: an open room for
##   everyone, a closed or direct one for its people. `Turbo::StreamsChannel` takes these and refuses the message
##   streams, so `RoomMessagesChannel` is the only door to those.
## - `user:ID:unreads`: `{"roomId":ID,"at":TIME}` for each message of a room that the person has unread or is connected
##   to (`UnreadRoomsChannel`).
##
## `PresenceChannel` (the room page, params `room_id`) tells the app that a tab is looking at the room: `Presence`
## keeps who, for `Presence.TTL_MS` after the last `refresh`, and the room is read for them. `HeartbeatChannel` only
## confirms. A handler runs on the loop of its connection, so each is short: a database call, no waiting.

import Bond from "pkg/bond/bond"
import Channels from "pkg/channels/channels"
import Db from "pkg/db/db"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import Database from "../campfire/repo/database"
import Hangup from "hangup"
import Presence from "../campfire/presence"
import Rooms from "../campfire/rooms"
import Routes from "routes"
import Views from "views"
import {Config} from "../campfire/config"

ROOM_MESSAGES_CHANNEL = "RoomMessagesChannel"
TURBO_CHANNEL = "Turbo::StreamsChannel"
ROOMS_STREAM = "rooms"
MESSAGES_SUFFIX = ":messages"
ROOM_PREFIX = "room:"

# How many times the membership of a room is looked up when the database is busy, and the pause after the first
# failure (it grows with each try).
MEMBER_TRIES = 3
MEMBER_PAUSE_MS = 50

# How long `stop` waits for the connections to say goodbye, and how often it looks.
GOODBYE_MS = 3_000
GOODBYE_POLL_MS = 50

# The room that a presence subscription or a stream name names, as a number.
NO_ROOM = -1

## What the routes and the handlers share: the hub that carries the broadcasts, the key that signs the stream names, the
## pool for the membership checks and the table of who is connected to which room.
export struct Cable
  hub: Channels.Hub
  key: Bytes
  pool: Database.Pool
  presence: Presence.Presence
end

# Who a connection is: the person and the token of the session that opened it, which `check_session` looks up again.
struct Seat
  user: Auth.User
  token: String
end

# What the fan-out of a message needs, in a task of its own: the room and the time of the message.
struct Unread
  cable: Cable
  room_id: Int
  at: String
end

# What the fan-out of a room that was made or renamed needs.
struct RoomEvent
  cable: Cable
  room_id: Int
  actor_id: Int
  renamed: Bool
end

# What the news of a deleted room needs: who was in it (the memberships are gone by now).
struct Gone
  cable: Cable
  room: Rooms.Room
  members: List[Int]
end

# A stream and the sidebar entry of the room that goes to it.
struct Delivery
  stream: String
  room: Rooms.Room
end

## Starts the hub and derives the key of the stream names from `SECRET_KEY_BASE` (the secret of a Rails app: a name that
## Rails signed with it verifies), or from the session secret when that is not set. An `error` is a start that could
## not make either.
export def start(config: Config, pool: Database.Pool) -> Result[Cable]
  secret = config.secret_key_base
  if secret.empty?
    secret = config.session_secret
  end

  key = try Channels.stream_key(secret)
  hub = try Channels.start_hub()
  return ok(Cable(hub: hub, key: key, pool: pool, presence: Presence.new()))
end

## Ends the hub: its connections are told to reconnect and are closed. It waits until the hub task is over, and then
## until the connections have said goodbye, for at most `GOODBYE_MS`: a connection finds out that the hub is gone at
## its next look (every 2 s), and a server that stopped before that would cut the sockets with no frame.
export def stop(cable: Cable) -> Void
  _ = Channels.stop_hub(cable.hub)
  _ = Task.await(cable.hub.task)
  waited = 0
  while Channels.stats(cable.hub).connections > 0 and waited < GOODBYE_MS
    Task.sleep(GOODBYE_POLL_MS)
    waited += GOODBYE_POLL_MS
  end
end

## Adds the WebSocket at `Routes.CABLE` to `app`. The sign-in filter lets the path through (`AuthWeb.PUBLIC_PATHS`),
## and `connect` looks up the session itself.
export def add(app: Bond.App, cable: Cable, config: Config) -> Bond.App
  origins: List[String] = []
  if not config.base_url.empty?
    origins = [config.base_url]
  end

  options = Channels.MountOptions(connect: connecting(cable), handlers: handlers(cable), allowed_origins: origins)
  # The settings are constants of this file, which `mount` accepts.
  mounted = Channels.mount(app, Routes.CABLE, cable.hub, options).unwrap!
  return mounted |> Bond.get(Routes.CABLE_STATS) do |conn| show_stats(conn, cable) end
end

## The `<turbo-cable-stream-source>` of the messages of the room, for the room page.
export def room_sources(cable: Cable, room_id: Int) -> String
  return source(cable, ROOM_MESSAGES_CHANNEL, messages_stream(room_id))
end

## The `<turbo-cable-stream-source>` elements of the sidebar of the person: the rooms of the account and their own.
export def sidebar_sources(cable: Cable, user_id: Int) -> String
  return [source(cable, TURBO_CHANNEL, ROOMS_STREAM), source(cable, TURBO_CHANNEL, user_rooms_stream(user_id))].join(
    "\n",
  )
end

## A message was stored: appends it to the page of everyone who is looking at the room, and tells the people it
## concerns that the room has something new. The second part runs in a task of its own, as Rails runs it in a job, so
## the post does not wait for a notice for each member. A broadcast that cannot be queued is counted as lost by the hub
## and does not fail the post.
export def message_created(cable: Cable, room: Rooms.Room, message: Rooms.Message) -> Void
  _ = Channels.broadcast_text(cable.hub, messages_stream(room.id), Views.message_stream(room, message, false))
  _ = Task.spawn(&unread_notices, Unread(cable: cable, room_id: room.id, at: message.created_at))
end

## A room was made (`renamed` false) or renamed: its entry goes to the sidebars that list it, in a task of its own.
## `actor_id` is the person who did it, who always sees the room.
export def room_changed(cable: Cable, room_id: Int, actor_id: Int, renamed: Bool) -> Void
  _ = Task.spawn(&room_news, RoomEvent(cable: cable, room_id: room_id, actor_id: actor_id, renamed: renamed))
end

## A room was deleted: the people looking at it are shown that it is gone, and it leaves the sidebars that listed it
## (an open room's entry goes to `rooms`, a closed or direct one to the people who were in it, as when it was made).
## It runs in a task of its own, for the same reason as `room_changed`. `members` are the people who were in it.
export def room_deleted(cable: Cable, room: Rooms.Room, members: List[Int]) -> Void
  _ = Task.spawn(&room_news_gone, Gone(cable: cable, room: room, members: members))
end

## Ends the sockets of the people who were taken out of a closed room, so that they reconnect and subscribe again only
## where they are still allowed (`Hangup.users`).
export def members_removed(cable: Cable, user_ids: List[Int]) -> Void
  Hangup.users(cable.hub, user_ids, true)
end

# What the hub counted, for an administrator: the connections and subscriptions now, and the connections it dropped for
# a full inbox and the broadcasts it could not queue since the start. A benchmark run reads there that no client was
# dropped and no broadcast was lost. Anyone else gets the 404 of a path with no route.
def show_stats(conn: Bond.Conn, cable: Cable) -> Result[Bond.Conn]
  user = try AuthWeb.assigned_user(conn)
  case user
    some(person) if person.role == Rooms.ADMINISTRATOR_ROLE_NAME ->
      return ok(Bond.json(conn, 200, JSON.from(Channels.stats(cable.hub))))
    _ -> return ok(Bond.text(conn, 404, Routes.MISSING))
  end
end

def source(cable: Cable, channel: String, name: String) -> String
  signed = Channels.signed_stream_name(cable.key, name)
  return (
    "<turbo-cable-stream-source channel=\"#{channel}\" signed-stream-name=\"#{signed}\">" +
    "</turbo-cable-stream-source>"
  )
end

def messages_stream(room_id: Int) -> String
  return "#{ROOM_PREFIX}#{room_id}#{MESSAGES_SUFFIX}"
end

def user_rooms_stream(user_id: Int) -> String
  return "user:#{user_id}:rooms"
end

def unreads_stream(user_id: Int) -> String
  return "user:#{user_id}:unreads"
end

# The number in `room:NUMBER:messages`, or `NO_ROOM` for any other name.
def room_of_stream(name: String) -> Int
  if not name.start_with?(ROOM_PREFIX) or not name.end_with?(MESSAGES_SUFFIX)
    return NO_ROOM
  end

  digits = name.slice(ROOM_PREFIX.length, name.length - ROOM_PREFIX.length - MESSAGES_SUFFIX.length)
  return digits.to_i.unwrap_or(NO_ROOM)
end

def seat_of(session: Channels.Session) -> Result[Seat]
  return JSON.decode(session.identity.data, Seat)
end

def user_of(session: Channels.Session) -> Result[Auth.User]
  seat = try seat_of(session)
  return ok(seat.user)
end

# True when the person has a membership of the room, whatever their involvement.
def member?(cable: Cable, session: Channels.Session, room_id: Int) -> Result[Bool]
  person = try user_of(session)
  found = try Database.with_connection(cable.pool) do |db| Rooms.find(db, person.id, room_id) end
  return ok(found.some?)
end

# The membership of a room, looked up again when the database fails (a reconnect burst can leave the pool without a
# connection for a moment). A failure that stays is not "not a member": the person's sockets are told to reconnect, so
# they ask again, and the failure is the answer (a subscription that fails is rejected, and the client keeps no stream
# that it was not given).
def checked_member(cable: Cable, session: Channels.Session, room_id: Int) -> Result[Bool]
  tries = 1
  found = member?(cable, session, room_id)
  while not found.ok? and tries < MEMBER_TRIES
    Task.sleep(MEMBER_PAUSE_MS * tries)
    tries += 1
    found = member?(cable, session, room_id)
  end

  if not found.ok?
    IO.warn("campfire: the membership of room #{room_id} could not be read: #{found.message}")
    _ = Channels.disconnect(cable.hub, session.identity.id, true)
  end

  return found
end

# The ones that `Channels.turbo_streams` asks. The room of a message stream comes from its verified name, so there
# is no parameter that a client could point somewhere else.
def message_stream_allowed?(cable: Cable, session: Channels.Session, name: String) -> Bool
  room_id = room_of_stream(name)
  if room_id == NO_ROOM
    return false
  end

  return checked_member(cable, session, room_id).unwrap_or(false)
end

def not_a_message_stream?(session: Channels.Session, name: String) -> Bool
  return not name.end_with?(MESSAGES_SUFFIX)
end

# The `room_id` of the params of a presence subscription, a number or the text of one.
def room_id_of(params: Json) -> Int
  field = JSON.get(params, "room_id")
  if not field.ok?
    return NO_ROOM
  end

  number = JSON.int(field.unwrap!)
  if number.ok?
    return number.unwrap!
  end

  text = JSON.string(field.unwrap!)
  if not text.ok?
    return NO_ROOM
  end

  return text.unwrap!.to_i.unwrap_or(NO_ROOM)
end

def connecting(cable: Cable) -> Fn[Bond.Conn, Result[Channels.Identity]]
  return opening() do |conn| identify(cable, conn) end
end

# A block cannot be assigned to a name: these give it a typed parameter first.
def opening(f: Fn[Bond.Conn, Result[Channels.Identity]]) -> Fn[Bond.Conn, Result[Channels.Identity]]
  return f
end

def subscribing(
  f: Fn[Channels.Session, Json, Result[Channels.Subscription]],
) -> Fn[Channels.Session, Json, Result[Channels.Subscription]]
  return f
end

def leaving(f: Fn[Channels.Session, Json, Result[Void]]) -> Fn[Channels.Session, Json, Result[Void]]
  return f
end

def acting(
  f: Fn[Channels.Session, Json, String, Json, Result[List[Json]]],
) -> Fn[Channels.Session, Json, String, Json, Result[List[Json]]]
  return f
end

def allowing(f: Fn[Channels.Session, String, Bool]) -> Fn[Channels.Session, String, Bool]
  return f
end

# The person of the session cookie, or an `error` that `/cable` answers with a `disconnect` that says not to retry.
def identify(cable: Cable, conn: Bond.Conn) -> Result[Channels.Identity]
  user = try AuthWeb.current_user(conn, cable.pool)
  case user
    none -> return error("no signed-in person")
    some(person) ->
      seat = Seat(user: person, token: AuthWeb.session_token(conn))
      return ok(Channels.Identity(id: Hangup.identity_of(person.id), data: JSON.from(seat)))
  end
end

def handlers(cable: Cable) -> Map[String, Channels.Handler]
  in_room = allowing() do |session, name| message_stream_allowed?(cable, session, name) end
  present = subscribing() do |session, params| present_in_room(cable, session, params) end
  absent = leaving() do |session, params| absent_from_room(cable, session, params) end
  refreshed = acting() do |session, params, action, _data| presence_action(cable, session, params, action) end
  unreads = subscribing() do |session, _params| unread_subscribed(session) end
  checked = acting() do |session, _params, _action, _data| check_session(cable, session) end
  return {
    ROOM_MESSAGES_CHANNEL: Channels.turbo_streams(cable.key, in_room),
    TURBO_CHANNEL: Channels.turbo_streams(cable.key, &not_a_message_stream?),
    "UnreadRoomsChannel": Channels.handler(unreads),
    "PresenceChannel": Channels.handler(present).with(unsubscribed: absent, perform: refreshed),
    "HeartbeatChannel": Channels.handler(&heartbeat_subscribed).with(perform: checked),
  }
end

def heartbeat_subscribed(session: Channels.Session, params: Json) -> Result[Channels.Subscription]
  return ok(Channels.Subscription())
end

def unread_subscribed(session: Channels.Session) -> Result[Channels.Subscription]
  person = try user_of(session)
  return ok(Channels.Subscription(streams: [unreads_stream(person.id)]))
end

# A member that looks at the room: one more tab, and the room is read. A non-member, or a params without a room, is
# rejected, and a rejection runs `absent`, which does nothing for a person who was never counted.
def present_in_room(cable: Cable, session: Channels.Session, params: Json) -> Result[Channels.Subscription]
  room_id = room_id_of(params)
  person = try user_of(session)
  if room_id == NO_ROOM or not try checked_member(cable, session, room_id)
    return ok(Channels.Subscription(rejected: true))
  end

  Presence.present(cable.presence, room_id, person.id, session.connection, Time.now_ms())
  read = Database.with_connection(cable.pool) do |db| Rooms.mark_read(db, room_id, person.id) end
  if not read.ok?
    IO.warn("campfire: room #{room_id} could not be marked read: #{read.message}")
  end

  return ok(Channels.Subscription())
end

def absent_from_room(cable: Cable, session: Channels.Session, params: Json) -> Result[Void]
  person = try user_of(session)
  Presence.absent(cable.presence, room_id_of(params), person.id, session.connection, Time.now_ms())
  return ok()
end

# The session of the connection is looked up again, so a socket that outlives its session (a sign-out in another
# browser, a password reset, a purge, the end of the cookie's life) does not keep listening. A session that is gone
# gets its person's sockets told to reconnect: the ones that still have a session are welcomed again at once, and this
# one is refused. A failure of the database leaves the socket as it is; the next check tries again.
def check_session(cable: Cable, session: Channels.Session) -> Result[List[Json]]
  seat = try seat_of(session)
  left = try Database.with_connection(cable.pool) do |db| Auth.seconds_left(db, seat.token) end
  if left == 0
    _ = Channels.disconnect(cable.hub, session.identity.id, true)
  end

  return ok([])
end

# `refresh` is what the page sends every 50 s while it is visible, and checks the session; `present` and `absent` are
# the same as the subscription and its end, for a page that comes back to the tab or leaves it. Any other action is
# ignored.
def presence_action(cable: Cable, session: Channels.Session, params: Json, action: String) -> Result[List[Json]]
  person = try user_of(session)
  room_id = room_id_of(params)
  now = Time.now_ms()
  case action
    "refresh" ->
      try check_session(cable, session)
      Presence.refresh(cable.presence, room_id, person.id, session.connection, now)
    "present" ->
      Presence.present(cable.presence, room_id, person.id, session.connection, now)
      _ = Database.with_connection(cable.pool) do |db| Rooms.mark_read(db, room_id, person.id) end
    "absent" -> Presence.absent(cable.presence, room_id, person.id, session.connection, now)
    _ -> return ok([])
  end

  return ok([])
end

# The members who have the room unread or are connected to it get `{"roomId":ID,"at":TIME}`. A message sets
# `unread_at` for everyone in the room but its author (the SQL of `Room#receive` looks at `memberships.connected_at`,
# which this app does not write), so the people who are looking at the room are marked read again here, in the same
# task: a room that someone watches is not left unread. A failure to read the members (no connection of the pool in
# time) ends the task and loses these notices without a trace: nothing counts them in `lost`, which is for broadcasts
# that could not be queued.
def unread_notices(job: Unread) -> Result[Void]
  cable = job.cable
  watchers = try Database.with_connection(cable.pool) do |db| Rooms.watchers(db, job.room_id) end
  now = Time.now_ms()
  notice = JSON.from({"roomId": JSON.from(job.room_id), "at": JSON.from(job.at)})
  watching: List[Int] = []
  for watcher in watchers
    connected = Presence.connected?(cable.presence, job.room_id, watcher.user_id, now)
    if connected
      watching = watching.push(watcher.user_id)
    end

    if watcher.unread or connected
      _ = Channels.broadcast_json(cable.hub, unreads_stream(watcher.user_id), notice)
    end
  end

  if watching.empty?
    return ok()
  end

  return Database.with_connection(cable.pool) do |db| Rooms.mark_read_all(db, job.room_id, watching) end
end

def room_news_gone(job: Gone) -> Result[Void]
  hub = job.cable.hub
  _ = Channels.broadcast_text(hub, messages_stream(job.room.id), Views.room_gone_stream(job.room))
  removal = Views.room_removed_stream(job.room)
  if job.room.room_type == Rooms.CLOSED or job.room.room_type == Rooms.DIRECT
    for user_id in job.members
      _ = Channels.broadcast_text(hub, user_rooms_stream(user_id), removal)
    end
  else
    _ = Channels.broadcast_text(hub, ROOMS_STREAM, removal)
  end

  return ok()
end

def room_news(job: RoomEvent) -> Result[Void]
  cable = job.cable
  deliveries = try Database.with_connection(cable.pool) do |db| deliveries_of(db, job) end
  for delivery in deliveries
    html = Views.room_added_stream(delivery.room)
    if job.renamed
      html = Views.room_renamed_stream(delivery.room)
    end

    _ = Channels.broadcast_text(cable.hub, delivery.stream, html)
  end

  return ok()
end

# An open room is one entry for everyone, a closed or direct one an entry for each person who lists it (a direct room
# is named after the other people, so each sees their own).
def deliveries_of(db: Db.Connection, job: RoomEvent) -> Result[List[Delivery]]
  seen = try Rooms.visible_room(db, job.actor_id, job.room_id)
  if seen.none?
    return ok([])
  end

  if seen.unwrap!.room_type != Rooms.CLOSED and seen.unwrap!.room_type != Rooms.DIRECT
    return ok([Delivery(stream: ROOMS_STREAM, room: seen.unwrap!)])
  end

  deliveries: List[Delivery] = []
  members = try Rooms.member_ids(db, job.room_id)
  for member in members
    room = try Rooms.visible_room(db, member, job.room_id)
    if room.some?
      deliveries = deliveries.push(Delivery(stream: user_rooms_stream(member), room: room.unwrap!))
    end
  end

  return ok(deliveries)
end

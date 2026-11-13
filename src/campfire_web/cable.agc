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
import Cache from "std/cache"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import Boosts from "../campfire/boosts"
import Database from "../campfire/repo/database"
import Hangup from "hangup"
import PageCache from "page_cache"
import Presence from "../campfire/presence"
import Rooms from "../campfire/rooms"
import Routes from "routes"
import Views from "views"
import {Config} from "../campfire/config"

## What the routes and the handlers share: the hub that carries the broadcasts, the key that signs the stream names, the
## pool for the membership checks, the table of who is connected to which room, and what the checks keep for a version
## of the database: the page cache (its observer gives the version, and it keeps the people of the sessions) and the
## memberships. With no page cache (`CAMPFIRE_RESPONSE_CACHE_MB=0`) nothing is kept and every check reads the database.
struct Cable
  hub: Channels.Hub
  key: Bytes
  pool: Database.Pool
  presence: Presence.Presence
  pages: Optional[PageCache.Pages]
  members: Cache.Store
  reads: ATS[String, Int]
end

## Starts the hub and derives the key of the stream names from `SECRET_KEY_BASE` (the secret of a Rails app: a name that
## Rails signed with it verifies), or from the session secret when that is not set. An `error` is a start that could
## not make either.
def start(config: Config, pool: Database.Pool, pages: Optional[PageCache.Pages]) -> Result[Cable]
  secret = config.secret_key_base
  if secret.empty?
    secret = config.session_secret
  end

  key = try Channels.stream_key(secret)
  hub = try Channels.start_hub()
  members = Cache.memory(MEMBER_CACHE_MB * BYTES_PER_MB)
  reads: ATS[String, Int] = ATS.new()
  ok(Cable(hub: hub, key: key, pool: pool, presence: Presence.new(), pages: pages, members: members, reads: reads))
end

## Ends the hub: its connections are told to reconnect and are closed. It waits until the hub task is over, and then
## until the connections have said goodbye, for at most `GOODBYE_MS`: a connection finds out that the hub is gone at
## its next look (every 2 s), and a server that stopped before that would cut the sockets with no frame.
def stop(cable: Cable) -> Void
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
def add(app: Bond.App, cable: Cable, config: Config) -> Bond.App
  origins: List[String] = []
  if not config.base_url.empty?
    origins = [config.base_url]
  end

  options = Channels.MountOptions(connect: connecting(cable), handlers: handlers(cable), allowed_origins: origins)
  # The settings are constants of this file, which `mount` accepts.
  mounted = Channels.mount(app, Routes.CABLE, cable.hub, options).unwrap!
  mounted |> Bond.get(Routes.CABLE_STATS) do |conn| show_stats(conn, cable) end
end

## The `<turbo-cable-stream-source>` of the messages of the room, for the room page.
def room_sources(cable: Cable, room_id: Int) -> String = source(cable, ROOM_MESSAGES_CHANNEL, messages_stream(room_id))

## The `<turbo-cable-stream-source>` elements of the sidebar of the person: the rooms of the account and their own.
def sidebar_sources(cable: Cable, user_id: Int) -> String
  [source(cable, TURBO_CHANNEL, ROOMS_STREAM), source(cable, TURBO_CHANNEL, user_rooms_stream(user_id))].join("\n")
end

## A message was stored: appends it to the page of everyone who is looking at the room, and tells the people it
## concerns that the room has something new. The second part runs in a task of its own, as Rails runs it in a job, so
## the post does not wait for a notice for each member. A broadcast that cannot be queued is counted as lost by the hub
## and does not fail the post.
def message_created(cable: Cable, room: Rooms.Room, message: Rooms.Message) -> Void
  message_announced(cable, room, message, Views.message_stream(room, message, false))
end

## `message_created` for a caller that has the stream of the message already (`Views.message_streams`, `broadcast`),
## so it is not written twice.
def message_announced(cable: Cable, room: Rooms.Room, message: Rooms.Message, stream: String) -> Void
  _ = Channels.broadcast_text(cable.hub, messages_stream(room.id), stream)
  # With no socket open nobody can hear a notice or be looking at the room (`Presence` is made of open sockets), and
  # the unread flag was stored by the post itself, so the task would only read the members to do nothing. A presence
  # entry that outlives a socket which died without a close handler (until its TTL) is not marked read either; the
  # person's next visit to the room marks it.
  if Channels.stats(cable.hub).connections > 0
    _ = Task.spawn(&unread_notices, Unread(cable: cable, room_id: room.id, at: message.created_at))
  end
end

## A message was edited or deleted: the people who are looking at the room see it replaced or gone.
def message_edited(cable: Cable, room: Rooms.Room, message: Rooms.Message) -> Void
  _ = Channels.broadcast_text(cable.hub, messages_stream(room.id), Views.message_replaced_stream(message))
end

def message_removed(cable: Cable, room_id: Int, message_id: Int) -> Void
  _ = Channels.broadcast_text(cable.hub, messages_stream(room_id), Views.message_removed(message_id))
end

## A boost was added to a message of the room, or taken away: it appears under the message, or leaves it, for the
## people who are looking at the room, as Rails appends it and removes it on the stream of the room's messages.
def boost_added(cable: Cable, room_id: Int, message_id: Int, boost: Boosts.Boost) -> Void
  _ = Channels.broadcast_text(cable.hub, messages_stream(room_id), Views.boost_added_stream(message_id, boost))
end

def boost_removed(cable: Cable, room_id: Int, boost_id: Int) -> Void
  _ = Channels.broadcast_text(cable.hub, messages_stream(room_id), Views.boost_removed_stream(boost_id))
end

## A room was made (`renamed` false) or renamed: its entry goes to the sidebars that list it, in a task of its own.
## `actor_id` is the person who did it, who always sees the room.
def room_changed(cable: Cable, room_id: Int, actor_id: Int, renamed: Bool) -> Void
  _ = Task.spawn(&room_news, RoomEvent(cable: cable, room_id: room_id, actor_id: actor_id, renamed: renamed))
end

## A room was deleted: the people looking at it are shown that it is gone, and it leaves the sidebars that listed it
## (an open room's entry goes to `rooms`, a closed or direct one to the people who were in it, as when it was made).
## It runs in a task of its own, for the same reason as `room_changed`. `members` are the people who were in it.
def room_deleted(cable: Cable, room: Rooms.Room, members: List[Int]) -> Void
  _ = Task.spawn(&room_news_gone, Gone(cable: cable, room: room, members: members))
end

## Ends the sockets of the people who were taken out of a closed room, so that they reconnect and subscribe again only
## where they are still allowed (`Hangup.users`).
def members_removed(cable: Cable, user_ids: List[Int]) -> Void
  Hangup.users(cable.hub, user_ids, true)
end

private

ROOM_MESSAGES_CHANNEL = "RoomMessagesChannel"
TURBO_CHANNEL = "Turbo::StreamsChannel"
ROOMS_STREAM = "rooms"
MESSAGES_SUFFIX = ":messages"
ROOM_PREFIX = "room:"
# How many times the membership of a room is looked up when the database is busy, and the pause after the first
# failure (it grows with each try).
MEMBER_TRIES = 3
MEMBER_PAUSE_MS = 50
# The megabytes of the memberships that the checks keep for a version of the database.
MEMBER_CACHE_MB = 1
# The names of the counters of `Cable.reads`.
SESSION_READS = "session_reads"
MEMBER_READS = "member_reads"
MARK_READS = "mark_reads"
# What a membership says besides the version it was read at: not in the room (never kept), in it and read, in it and
# unread.
OUTSIDE = "outside"
READ = "read"
UNREAD = "unread"
# How long `stop` waits for the connections to say goodbye, and how often it looks.
GOODBYE_MS = 3_000
GOODBYE_POLL_MS = 50
# The room that a presence subscription or a stream name names, as a number.
NO_ROOM = -1
BYTES_PER_MB = 1024 * 1024

# What `/cable/stats` shows besides the hub's counts: the reads of the database that the checks made (not the ones a
# kept answer saved) and the `mark_read` writes of the presence subscriptions, since the start.
struct Counts
  connections: Int
  subscriptions: Int
  drops: Int
  lost: Int
  session_reads: Int
  member_reads: Int
  mark_reads: Int
end

# What a check of the membership of a room found, and the version of the database it was read at ("" when it was read
# with no version): the person is in the room (`member`), and the room is unread for them.
struct Standing
  member: Bool
  unread: Bool
  version: String
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

# What the hub counted, for an administrator: the connections and subscriptions now, and the connections it dropped for
# a full inbox and the broadcasts it could not queue since the start. A benchmark run reads there that no client was
# dropped and no broadcast was lost; the reads of the checks are there for the specs that a kept answer is used.
# Anyone else gets the 404 of a path with no route.
def show_stats(conn: Bond.Conn, cable: Cable) -> Result[Bond.Conn]
  user = try AuthWeb.assigned_user(conn)
  case user
    some(person) if person.role == Rooms.ADMINISTRATOR_ROLE_NAME -> ok(Bond.json(conn, 200, JSON.from(counts(cable))))
    _ -> ok(Bond.text(conn, 404, Routes.MISSING))
  end
end

def counts(cable: Cable) -> Counts
  hub = Channels.stats(cable.hub)
  Counts(
    connections: hub.connections,
    subscriptions: hub.subscriptions,
    drops: hub.drops,
    lost: hub.lost,
    session_reads: ATS.get(cable.reads, SESSION_READS).unwrap_or(0),
    member_reads: ATS.get(cable.reads, MEMBER_READS).unwrap_or(0),
    mark_reads: ATS.get(cable.reads, MARK_READS).unwrap_or(0),
  )
end

def source(cable: Cable, channel: String, name: String) -> String
  signed = Channels.signed_stream_name(cable.key, name)
  (
    "<turbo-cable-stream-source channel=\"#{channel}\" signed-stream-name=\"#{signed}\">" +
    "</turbo-cable-stream-source>"
  )
end

def messages_stream(room_id: Int) -> String = "#{ROOM_PREFIX}#{room_id}#{MESSAGES_SUFFIX}"

def user_rooms_stream(user_id: Int) -> String = "user:#{user_id}:rooms"

def unreads_stream(user_id: Int) -> String = "user:#{user_id}:unreads"

# The number in `room:NUMBER:messages`, or `NO_ROOM` for any other name.
def room_of_stream(name: String) -> Int
  return NO_ROOM if not name.start_with?(ROOM_PREFIX) or not name.end_with?(MESSAGES_SUFFIX)

  digits = name.slice(ROOM_PREFIX.length, name.length - ROOM_PREFIX.length - MESSAGES_SUFFIX.length)
  digits.to_i.unwrap_or(NO_ROOM)
end

def seat_of(session: Channels.Session) -> Result[Seat] = JSON.decode(session.identity.data, Seat)

def user_of(session: Channels.Session) -> Result[Auth.User]
  seat = try seat_of(session)
  ok(seat.user)
end

# The membership of the person in the room, whatever their involvement, kept for the version of the database. The
# version is read before the lookup, so what is kept under it is what the database held at that version or later; a
# removal from the room, like any other commit, is another version, and the next check reads the database again. A
# person who lost a room therefore never passes on a kept answer. With no version (no page cache, or an observer that
# fails) the database is read every time.
def standing(cable: Cable, session: Channels.Session, room_id: Int) -> Result[Standing]
  person = try user_of(session)
  version = PageCache.current_version(cable.pages)
  key = "member:#{person.id}:#{room_id}"
  if version.some?
    kept = Cache.get(cable.members, key).unwrap_or("").split("\n")
    return ok(standing_of(version.unwrap!, kept[1])) if kept.size == 2 and kept[0] == version.unwrap!
  end

  ATS.add(cable.reads, MEMBER_READS, 1)
  found = try Database.with_connection(cable.pool) do |db| Rooms.membership(db, person.id, room_id) end
  return ok(Standing(member: found.some?, unread: found.unwrap_or(false), version: "")) if version.none?

  # Only a membership is kept: an answer "outside" is asked for any room number a client names, so keeping it would let
  # one client push the entries of the others out of the store. It costs a read, as it always did.
  return ok(standing_of(version.unwrap!, OUTSIDE)) if found.none?

  answer = READ
  if found.unwrap!
    answer = UNREAD
  end

  Cache.put(cable.members, key, "#{version.unwrap!}\n#{answer}")
  ok(standing_of(version.unwrap!, answer))
end

def standing_of(version: String, answer: String) -> Standing
  Standing(member: answer != OUTSIDE, unread: answer == UNREAD, version: version)
end

# `standing`, looked up again when the database fails (a reconnect burst can leave the pool without a connection for
# a moment). A failure that stays is not "not a member": it is the answer, and it refuses this subscription only. The
# client keeps no stream that it was not given, and the Turbo client does not ask again, so that tab has no live
# stream of the room until its page is loaded again. The person's other sockets are not touched: they were checked
# when they were made, and a failure of the database says nothing about their right to be there.
def checked_standing(cable: Cable, session: Channels.Session, room_id: Int) -> Result[Standing]
  tries = 1
  found = standing(cable, session, room_id)
  while not found.ok? and tries < MEMBER_TRIES
    Task.sleep(MEMBER_PAUSE_MS * tries)
    tries += 1
    found = standing(cable, session, room_id)
  end

  if not found.ok?
    IO.warn("campfire: the membership of room #{room_id} could not be read: #{found.message}")
  end

  found
end

# The ones that `Channels.turbo_streams` asks. The room of a message stream comes from its verified name, so there
# is no parameter that a client could point somewhere else.
def message_stream_allowed?(cable: Cable, session: Channels.Session, name: String) -> Bool
  room_id = room_of_stream(name)
  return false if room_id == NO_ROOM

  found = checked_standing(cable, session, room_id)
  found.ok? and found.unwrap!.member
end

def not_a_message_stream?(session: Channels.Session, name: String) -> Bool = not name.end_with?(MESSAGES_SUFFIX)

# The `room_id` of the params of a presence subscription, a number or the text of one.
def room_id_of(params: JSON.Value) -> Int
  field = JSON.get(params, "room_id")
  return NO_ROOM if not field.ok?

  number = JSON.int(field.unwrap!)
  return number.unwrap! if number.ok?

  text = JSON.string(field.unwrap!)
  return NO_ROOM if not text.ok?

  text.unwrap!.to_i.unwrap_or(NO_ROOM)
end

def connecting(cable: Cable) -> Fn[Bond.Conn, Result[Channels.Identity]] = opening do |conn| identify(cable, conn) end

# A block cannot be assigned to a name: these give it a typed parameter first.
def opening(f: Fn[Bond.Conn, Result[Channels.Identity]]) -> Fn[Bond.Conn, Result[Channels.Identity]] = f

def subscribing(
  f: Fn[Channels.Session, JSON.Value, Result[Channels.Subscription]],
) -> Fn[Channels.Session, JSON.Value, Result[Channels.Subscription]]
  f
end

def leaving(f: Fn[Channels.Session, JSON.Value, Result[Void]]) -> Fn[Channels.Session, JSON.Value, Result[Void]] = f

def acting(
  f: Fn[Channels.Session, JSON.Value, String, JSON.Value, Result[List[JSON.Value]]],
) -> Fn[Channels.Session, JSON.Value, String, JSON.Value, Result[List[JSON.Value]]]
  f
end

def allowing(f: Fn[Channels.Session, String, Bool]) -> Fn[Channels.Session, String, Bool] = f

# The person of the session cookie, or an `error` that `/cable` answers with a `disconnect` that says not to retry.
def identify(cable: Cable, conn: Bond.Conn) -> Result[Channels.Identity]
  user = try session_person(cable, AuthWeb.session_token(conn))
  case user
    none -> error("no signed-in person")
    some(person) ->
      seat = Seat(user: person, token: AuthWeb.session_token(conn))
      ok(Channels.Identity(id: Hangup.identity_of(person.id), data: JSON.from(seat)))
  end
end

# The person of the session with `token`, as `AuthWeb` finds them for a page: the one kept for the version of the
# database (a sign-out, a deactivation, a ban or a change of the person is a commit, so another version), else the one
# the database gives, which is then kept. A burst of sockets of one session reads it once.
def session_person(cable: Cable, token: String) -> Result[Optional[Auth.User]]
  return ok(none) if token.empty?

  seen = PageCache.current_version(cable.pages)
  kept = PageCache.known_user(cable.pages, seen, token)
  return ok(kept) if kept.some?

  ATS.add(cable.reads, SESSION_READS, 1)
  found = try Database.with_connection(cable.pool) do |db| Auth.user_for(db, token) end
  case found
    some(session) ->
      PageCache.remember_user(cable.pages, seen, token, session)
      ok(some(session.user))
    none -> ok(none)
  end
end

def handlers(cable: Cable) -> Map[String, Channels.Handler]
  in_room = allowing do |session, name| message_stream_allowed?(cable, session, name) end
  present = subscribing do |session, params| present_in_room(cable, session, params) end
  absent = leaving do |session, params| absent_from_room(cable, session, params) end
  refreshed = acting do |session, params, action, _data| presence_action(cable, session, params, action) end
  unreads = subscribing do |session, _params| unread_subscribed(session) end
  checked = acting do |session, _params, _action, _data| check_session(cable, session) end
  {
    ROOM_MESSAGES_CHANNEL: Channels.turbo_streams(cable.key, in_room),
    TURBO_CHANNEL: Channels.turbo_streams(cable.key, &not_a_message_stream?),
    "UnreadRoomsChannel": Channels.handler(unreads),
    "PresenceChannel": Channels.handler(present).with(unsubscribed: absent, perform: refreshed),
    "HeartbeatChannel": Channels.handler(&heartbeat_subscribed).with(perform: checked),
  }
end

def heartbeat_subscribed(session: Channels.Session, params: JSON.Value) -> Result[Channels.Subscription]
  ok(Channels.Subscription())
end

def unread_subscribed(session: Channels.Session) -> Result[Channels.Subscription]
  person = try user_of(session)
  ok(Channels.Subscription(streams: [unreads_stream(person.id)]))
end

# A member that looks at the room: one more tab, and the room is read. A non-member, or a params without a room, is
# rejected, and a rejection runs `absent`, which does nothing for a person who was never counted.
def present_in_room(cable: Cable, session: Channels.Session, params: JSON.Value) -> Result[Channels.Subscription]
  room_id = room_id_of(params)
  person = try user_of(session)
  return ok(Channels.Subscription(rejected: true)) if room_id == NO_ROOM

  found = try checked_standing(cable, session, room_id)
  return ok(Channels.Subscription(rejected: true)) if not found.member

  Presence.present(cable.presence, room_id, person.id, session.connection, Time.now_ms())
  if should_mark_read?(cable, found)
    ATS.add(cable.reads, MARK_READS, 1)
    read = Database.with_connection(cable.pool) do |db| Rooms.mark_read(db, room_id, person.id) end
    if not read.ok?
      IO.warn("campfire: room #{room_id} could not be marked read: #{read.message}")
    end
  end

  ok(Channels.Subscription())
end

# False only when the room is known to be read: it was read when the membership was looked up, and the database has had
# no commit since (the person is counted as present by now, so a message after that marks the room read itself). A
# commit in between could be a message that came before the presence did, so the room is marked read, as it always is
# with no version to compare.
def should_mark_read?(cable: Cable, found: Standing) -> Bool
  return true if found.unread or found.version.empty?

  now = PageCache.current_version(cable.pages)
  now.none? or now.unwrap! != found.version
end

def absent_from_room(cable: Cable, session: Channels.Session, params: JSON.Value) -> Result[Void]
  person = try user_of(session)
  Presence.absent(cable.presence, room_id_of(params), person.id, session.connection, Time.now_ms())
  ok()
end

# The session of the connection is looked up again, so a socket that outlives its session (a sign-out in another
# browser, a password reset, a purge, the end of the cookie's life) does not keep listening. A session that is gone
# gets its person's sockets told to reconnect: the ones that still have a session are welcomed again at once, and this
# one is refused. A failure of the database leaves the socket as it is; the next check tries again.
def check_session(cable: Cable, session: Channels.Session) -> Result[List[JSON.Value]]
  seat = try seat_of(session)
  left = try Database.with_connection(cable.pool) do |db| Auth.seconds_left(db, seat.token) end
  if left == 0
    _ = Channels.disconnect(cable.hub, session.identity.id, true)
  end

  ok([])
end

# `refresh` is what the page sends every 50 s while it is visible, and checks the session; `present` and `absent` are
# the same as the subscription and its end, for a page that comes back to the tab or leaves it. Any other action is
# ignored.
def presence_action(
  cable: Cable,
  session: Channels.Session,
  params: JSON.Value,
  action: String,
) -> Result[List[JSON.Value]]
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

  ok([])
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

  return ok() if watching.empty?

  Database.with_connection(cable.pool) do |db| Rooms.mark_read_all(db, job.room_id, watching) end
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

  ok()
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

  ok()
end

# An open room is one entry for everyone, a closed or direct one an entry for each person who lists it (a direct room
# is named after the other people, so each sees their own).
def deliveries_of(db: Db.Connection, job: RoomEvent) -> Result[List[Delivery]]
  seen = try Rooms.visible_room(db, job.actor_id, job.room_id)
  return ok([]) if seen.none?

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

  ok(deliveries)
end

## Rooms, their members and their messages over the `rooms`, `memberships` and `messages` tables. These functions take
## an open connection and never see a request. A person is in a room when a `memberships` row says so, whatever the
## kind of the room: an open room is one that every active person has a row in, which `create_open_in` and
## `grant_open_rooms` write. Every lookup for a person goes through that row, so a room of someone else is `none`
## exactly as a room that does not exist is, and a caller cannot tell them apart.

import Db from "pkg/db/db"
import {int_of, text_of} from "rows"

## How many messages a page of a room holds.
export PAGE_SIZE = 40

## The kind of a room between people, which has no name of its own.
export DIRECT = "direct"

## The longest name of a room, in characters, and the longest message.
export MAX_NAME_LENGTH = 100
export MAX_BODY_LENGTH = 10_000

## The `client_message_id` that the form of a room page carries is a random hex string, so nothing longer is real.
export MAX_CLIENT_ID_LENGTH = 64

NAME_PROBLEM = "Give the room a name of 1 to #{MAX_NAME_LENGTH} characters"
BODY_BLANK = "Write something to send"
BODY_LONG = "A message is at most #{MAX_BODY_LENGTH} characters"
NO_NAME = "Direct message"

# Greater than any id, so that "before this id" with no id is the whole room.
NEWEST = 9_223_372_036_854_775_807

# A room as a person sees it. A direct room has no name, so it is called after the other people in it (the column is
# `others`), and `memberships.involvement` is what the sidebar filters on. The names are joined in the order of the
# inner select, which the database keeps for `group_concat` in practice.
ROOM_COLUMNS = (
  "select rooms.id, rooms.kind, rooms.name, " +
  "(select group_concat(name, ', ') from (select users.name as name from memberships others " +
  "join users on users.id = others.user_id where others.room_id = rooms.id and others.user_id <> ? " +
  "order by users.name)) as others " +
  "from memberships join rooms on rooms.id = memberships.room_id where memberships.user_id = ?"
)

## A room of a person. `name` is what to call it for them: its own name, or for a direct room the other people.
export struct Room
  id: Int
  name: String
  kind: String
end

## A message with the name of its author. `created_at` is the text of the schema (UTC, ISO 8601).
export struct Message
  id: Int
  author: String
  body: String
  created_at: String
end

## A page of a room, oldest message first. `older` is the cursor of the page before it (`before=` of `page`), `none`
## when this one reaches the first message. `at_latest` is false for a page that was asked for with a cursor.
export struct Page
  messages: List[Message]
  older: Optional[Int]
  at_latest: Bool
end

## What is wrong with a room name, or "". The caller strips it first.
export def name_problem(name: String) -> String
  if name.empty? or name.length > MAX_NAME_LENGTH
    return NAME_PROBLEM
  end

  return ""
end

## What is wrong with a message body, or "". The caller strips it first.
export def body_problem(body: String) -> String
  if body.empty?
    return BODY_BLANK
  end

  if body.length > MAX_BODY_LENGTH
    return BODY_LONG
  end

  return ""
end

## The rooms that the person shows in their sidebar: every room they are in, except the ones they set to invisible,
## by name.
export def visible(conn: Db.Connection, user_id: Int) -> Result[List[Room]]
  rows = try Db.query(
    conn,
    "select * from (#{ROOM_COLUMNS} and memberships.involvement <> 'invisible') " +
    "order by lower(coalesce(name, others, '')), id",
    [Db.Value.Int(user_id), Db.Value.Int(user_id)],
  )

  return ok(rows.map do |row| room_of(row) end)
end

## The room, when the person is in it (any involvement), and `none` for a room that does not exist and for one that
## the person is not in.
export def find(conn: Db.Connection, user_id: Int, room_id: Int) -> Result[Optional[Room]]
  rows = try Db.query(
    conn,
    "#{ROOM_COLUMNS} and rooms.id = ?",
    [Db.Value.Int(user_id), Db.Value.Int(user_id), Db.Value.Int(room_id)],
  )

  if rows.empty?
    return ok(none)
  end

  return ok(some(room_of(rows[0])))
end

## Makes an open room that `creator_id` made and puts every active person in it, in one transaction. It gives the id.
export def create_open(conn: Db.Connection, creator_id: Int, name: String) -> Result[Int]
  return Db.transaction(conn) do |tx| create_open_in(tx, creator_id, name) end
end

## `create_open` inside a transaction that the caller has begun (the first run makes its room in the transaction that
## makes the administrator). The creator must be an active user, or they are not in their own room.
export def create_open_in(tx: Db.Connection, creator_id: Int, name: String) -> Result[Int]
  rooms = try Db.query(
    tx,
    "insert into rooms (name, kind, creator_id) values (?, 'open', ?) returning id",
    [Db.Value.Text(name), Db.Value.Int(creator_id)],
  )

  room_id = int_of(rooms[0], "id")
  try Db.execute(
    tx,
    "insert into memberships (room_id, user_id) select ?, id from users where active = 1",
    [Db.Value.Int(room_id)],
  )

  return ok(room_id)
end

## Puts the person in every open room, for whoever makes a user after the rooms exist (an invitation). A room that
## they are in already is left as it is.
export def grant_open_rooms(conn: Db.Connection, user_id: Int) -> Result[Void]
  try Db.execute(
    conn,
    "insert into memberships (room_id, user_id) select id, ? from rooms where kind = 'open' " +
    "on conflict (room_id, user_id) do nothing",
    [Db.Value.Int(user_id)],
  )

  return ok()
end

## The newest `PAGE_SIZE` messages of the room that come before the message `before` (all of them without it), oldest
## first. It reads one more than a page, to know whether there is an older page without a count. Paged by `id`, never
## by `created_at`, which can tie (see `migrations.agc`).
export def page(conn: Db.Connection, room_id: Int, before: Optional[Int]) -> Result[Page]
  rows = try Db.query(
    conn,
    "select messages.id, users.name as author, messages.body, messages.created_at " +
    "from messages join users on users.id = messages.creator_id " +
    "where messages.room_id = ? and messages.id < ? order by messages.id desc limit ?",
    [Db.Value.Int(room_id), Db.Value.Int(before.unwrap_or(NEWEST)), Db.Value.Int(PAGE_SIZE + 1)],
  )

  shown = rows.take(PAGE_SIZE).map do |row| message_of(row) end
  older: Optional[Int] = none
  if rows.size > PAGE_SIZE
    older = some(shown.last.id)
  end

  return ok(Page(messages: shown.reverse, older: older, at_latest: before.none?))
end

## Stores a message of the person in the room, which the caller has checked they are in. `client_message_id` is made by
## the page of the form: a second post with the same one (a double click, a retry after a lost answer) stores
## nothing, so one send is one message.
export def post(
  conn: Db.Connection,
  room_id: Int,
  user_id: Int,
  client_message_id: String,
  body: String,
) -> Result[Void]
  try Db.execute(
    conn,
    "insert into messages (room_id, creator_id, body, client_message_id) values (?, ?, ?, ?) " +
    "on conflict (creator_id, client_message_id) do nothing",
    [Db.Value.Int(room_id), Db.Value.Int(user_id), Db.Value.Text(body), Db.Value.Text(client_message_id)],
  )

  return ok()
end

def room_of(row: Db.Row) -> Room
  kind = text_of(row, "kind")
  name = text_of(row, "name")
  if kind == DIRECT
    name = text_of(row, "others")
  end

  if name.empty?
    name = NO_NAME
  end

  return Room(id: int_of(row, "id"), name: name, kind: kind)
end

def message_of(row: Db.Row) -> Message
  return Message(
    id: int_of(row, "id"),
    author: text_of(row, "author"),
    body: text_of(row, "body"),
    created_at: text_of(row, "created_at"),
  )
end

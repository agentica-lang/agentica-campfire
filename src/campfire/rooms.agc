## Rooms, their members and their messages over the `rooms`, `memberships` and `messages` tables. These functions take
## an open connection and never see a request. A person is in a room when a `memberships` row says so, whatever the
## kind of the room: an open room is one that every active person has a row in, which `create_open_in` and
## `grant_open_rooms` write. Every lookup for a person goes through that row, so a room of someone else is `none`
## exactly as a room that does not exist is, and a caller cannot tell them apart.

import Db from "pkg/db/db"
import Rails from "repo/rails"
import {int_of, text_of} from "repo/rows"

## How many messages a page of a room holds.
export PAGE_SIZE = 40

## The kinds of room that this module makes besides the open one: a room with a member list, and a room between people,
## which has no name of its own.
export CLOSED = "closed"
export DIRECT = "direct"

## The role of an account administrator, who may edit any closed room (`users.role`).
export ADMINISTRATOR = Rails.ADMINISTRATOR_NAME

## The longest name of a room, in characters, and the longest message.
export MAX_NAME_LENGTH = 100
export MAX_BODY_LENGTH = 10_000

## The `client_message_id` that the form of a room page carries is a random hex string, so nothing longer is real.
export MAX_CLIENT_ID_LENGTH = 64

NAME_PROBLEM = "Give the room a name of 1 to #{MAX_NAME_LENGTH} characters"
BODY_BLANK = "Write something to send"
BODY_LONG = "A message is at most #{MAX_BODY_LENGTH} characters"
NO_PEOPLE = "Choose at least one person"
NO_NAME = "Direct message"

# What `updated_at` is set to when a room changes, in the form of the schema.
NOW = Rails.NOW

# Greater than any id, so that "before this id" with no id is the whole room.
NEWEST = 9_223_372_036_854_775_807

# A room as a person sees it. A direct room has no name, so it is called after the other people in it (the column is
# `others`, looked up only for a direct room, so an open room costs no subquery), and `memberships.involvement` is
# what the sidebar filters on. The names are joined in the order of the inner select, which the database keeps for
# `group_concat` in practice.
ROOM_COLUMNS = (
  "select rooms.id, rooms.kind, rooms.name, rooms.creator_id, " +
  "case when rooms.kind = 'direct' then " +
  "(select group_concat(name, ', ') from (select users.name as name from memberships others " +
  "join users on users.id = others.user_id where others.room_id = rooms.id and others.user_id <> ? " +
  "order by users.name)) end as others " +
  "from memberships join rooms on rooms.id = memberships.room_id where memberships.user_id = ?"
)

## A room of a person. `name` is what to call it for them: its own name, or for a direct room the other people.
export struct Room
  id: Int
  name: String
  kind: String
  creator_id: Int
end

## A person that a room form offers, an active user.
export struct Person
  id: Int
  name: String
end

## A message with the name of its author. `created_at` is an ISO 8601 UTC instant with milliseconds
## (`2026-03-01T09:00:00.123Z`), made from the Rails form of the column, so that `<time datetime>` and the scripts that
## read it take it as UTC.
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

## What is wrong with the people of a direct message, or "": it needs one besides the person who starts it.
export def people_problem(chosen: List[Int]) -> String
  if chosen.empty?
    return NO_PEOPLE
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
    "insert into memberships (room_id, user_id) select ?, id from users where status = #{Rails.ACTIVE}",
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

## True when the person may change the room: it is a closed room and they made it or are an account administrator, as
## upstream lets only the creator and an administrator administer a room. Being in the room is not enough.
export def editable?(room: Room, user_id: Int, role: String) -> Bool
  return room.kind == CLOSED and (room.creator_id == user_id or role == ADMINISTRATOR)
end

## The active people that a person can put in a room, other than themselves (they are always in what they make), by
## name.
export def people(conn: Db.Connection, user_id: Int) -> Result[List[Person]]
  rows = try Db.query(
    conn,
    "select id, name from users where status = #{Rails.ACTIVE} and id <> ? order by lower(name), id",
    [Db.Value.Int(user_id)],
  )

  return ok(rows.map do |row| Person(id: int_of(row, "id"), name: text_of(row, "name")) end)
end

## The ids of everyone in the room, the people who are not active included.
export def member_ids(conn: Db.Connection, room_id: Int) -> Result[List[Int]]
  rows = try Db.query(conn, "select user_id from memberships where room_id = ?", [Db.Value.Int(room_id)])
  return ok(rows.map do |row| int_of(row, "user_id") end)
end

## Makes a closed room of `creator_id` with them and `members` in it, in one transaction, and gives its id. A member
## that is not an active user is left out, and the creator may be in `members`.
export def create_closed(conn: Db.Connection, creator_id: Int, name: String, members: List[Int]) -> Result[Int]
  return Db.transaction(conn) do |tx| create_closed_in(tx, creator_id, name, members) end
end

## Renames the closed room and applies the diff of the form, and nothing else: the people in `chosen` and not in `was`
## (who were in the room when the form was drawn) are added, and the ones in `was` and not in `chosen` are taken out.
## What the form did not change is left as it is, so a stale form neither takes out someone who was put in after it
## was drawn nor brings back someone who was taken out. Someone who is not active now stays, and so does `editor_id`,
## the person who sends the form, who is never offered. It gives false, and changes nothing, when the room is not closed
## or `editor_id` may not edit it or is not in it (they were taken out, or lost the role, since the caller looked); the
## active people are read inside the transaction for the same reason. An error is a failure of the database.
export def update_closed(
  conn: Db.Connection,
  room_id: Int,
  editor_id: Int,
  name: String,
  chosen: List[Int],
  was: List[Int],
) -> Result[Bool]
  return Db.transaction(conn) do |tx| update_closed_in(tx, room_id, editor_id, name, chosen, was) end
end

## The direct room between `creator_id` and `others` (the people they picked, not themselves), which is the one that
## exists with exactly those people in it, or a new one; `none` when no active person is left among `others`. The
## people are checked, the room is searched for and it is made in one write transaction, so a person who is made
## inactive meanwhile does not make a room with fewer people than the search counted, and two requests for the same
## people get one room.
export def open_direct(conn: Db.Connection, creator_id: Int, others: List[Int]) -> Result[Optional[Int]]
  return Db.transaction(conn) do |tx| open_direct_in(tx, creator_id, others) end
end

## The newest `PAGE_SIZE` messages of the room that come before the message `before` (all of them without it), oldest
## first. It reads one more than a page, to know whether there is an older page without a count. Paged by `id`, never
## by `created_at`, which can tie (see `repo/migrations.agc`).
export def page(conn: Db.Connection, room_id: Int, before: Optional[Int]) -> Result[Page]
  rows = try Db.query(
    conn,
    "select messages.id, users.name as author, messages.body, " +
    "strftime('%Y-%m-%dT%H:%M:%fZ', messages.created_at) as created_at " +
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

## Stores a message of the person in the room, which the caller has checked they are in, and says whether the person
## is still active: the insert itself needs an active person, so a deactivation that came after the sign-in check (the
## request may have waited for a connection) stores nothing and gives `false`. `client_message_id` is made by the page
## of the form: a second post with the same one (a double click, a retry after a lost answer) stores nothing, so one
## send is one message. It must be unique per person, not per room: the key is the person and the id, so a reuse in
## another room is dropped without a word.
export def post(
  conn: Db.Connection,
  room_id: Int,
  user_id: Int,
  client_message_id: String,
  body: String,
) -> Result[Bool]
  stored = try Db.execute(
    conn,
    "insert into messages (room_id, creator_id, body, client_message_id) " +
    "select ?, ?, ?, ? where exists (select 1 from users where id = ? and status = #{Rails.ACTIVE}) " +
    "on conflict (creator_id, client_message_id) do nothing",
    [
      Db.Value.Int(room_id),
      Db.Value.Int(user_id),
      Db.Value.Text(body),
      Db.Value.Text(client_message_id),
      Db.Value.Int(user_id),
    ],
  )

  if stored > 0
    return ok(true)
  end

  # Nothing was stored: either the message was a repeat (the person is active) or the person is not.
  rows = try Db.query(conn, "select 1 from users where id = ? and status = #{Rails.ACTIVE}", [Db.Value.Int(user_id)])
  return ok(not rows.empty?)
end

def create_closed_in(tx: Db.Connection, creator_id: Int, name: String, members: List[Int]) -> Result[Int]
  room_id = try insert_room(tx, Db.Value.Text(name), CLOSED, creator_id)
  try add_member(tx, room_id, creator_id, "mentions")
  for member in members
    try add_member(tx, room_id, member, "mentions")
  end

  return ok(room_id)
end

def update_closed_in(
  tx: Db.Connection,
  room_id: Int,
  editor_id: Int,
  name: String,
  chosen: List[Int],
  was: List[Int],
) -> Result[Bool]
  changed = try Db.execute(
    tx,
    "update rooms set name = ?, updated_at = #{NOW} where id = ? and kind = 'closed' " +
    "and (creator_id = ? or exists (select 1 from users where id = ? and role = #{Rails.ADMINISTRATOR} and " +
    "status = #{Rails.ACTIVE})) " +
    "and exists (select 1 from memberships where room_id = rooms.id and user_id = ?)",
    [
      Db.Value.Text(name),
      Db.Value.Int(room_id),
      Db.Value.Int(editor_id),
      Db.Value.Int(editor_id),
      Db.Value.Int(editor_id),
    ],
  )

  # Nothing was written yet, so refusing here leaves the room as it was.
  if changed != 1
    return ok(false)
  end

  for person in try people(tx, editor_id)
    if chosen.include?(person.id) and not was.include?(person.id)
      try add_member(tx, room_id, person.id, "mentions")
    elsif was.include?(person.id) and not chosen.include?(person.id)
      try Db.execute(
        tx,
        "delete from memberships where room_id = ? and user_id = ?",
        [Db.Value.Int(room_id), Db.Value.Int(person.id)],
      )
    end
  end

  return ok(true)
end

def open_direct_in(tx: Db.Connection, creator_id: Int, others: List[Int]) -> Result[Optional[Int]]
  everyone = try active_among(tx, [creator_id].concat(others).uniq)
  if everyone.size < 2 or not everyone.include?(creator_id)
    return ok(none)
  end

  existing = try direct_between(tx, everyone)
  case existing
    some(room_id) -> return ok(some(room_id))
    none -> return ok(some(try make_direct(tx, creator_id, everyone)))
  end
end

# The ids among `ids` that are active users now, so that what is searched for is what gets inserted.
def active_among(tx: Db.Connection, ids: List[Int]) -> Result[List[Int]]
  marks = ids.map do |_| "?" end.join(", ")
  rows = try Db.query(
    tx,
    "select id from users where status = #{Rails.ACTIVE} and id in (#{marks}) order by id",
    ids.map do |id| Db.Value.Int(id) end,
  )

  return ok(rows.map do |row| int_of(row, "id") end)
end

# A direct room that has all of `everyone` in it and nobody else: as many members as people, and all of them among
# the people (a room with the same count but another person is not it).
def direct_between(tx: Db.Connection, everyone: List[Int]) -> Result[Optional[Int]]
  marks = everyone.map do |_| "?" end.join(", ")
  size = Db.Value.Int(everyone.size)
  rows = try Db.query(
    tx,
    "select rooms.id from rooms where rooms.kind = 'direct' " +
    "and (select count(*) from memberships where room_id = rooms.id) = ? " +
    "and (select count(*) from memberships where room_id = rooms.id and user_id in (#{marks})) = ? " +
    "order by rooms.id limit 1",
    [size].concat(everyone.map do |id| Db.Value.Int(id) end).push(size),
  )

  if rows.empty?
    return ok(none)
  end

  return ok(some(int_of(rows[0], "id")))
end

# Everyone is in at once, and sees every message ("everything" is what upstream gives a direct room).
def make_direct(tx: Db.Connection, creator_id: Int, everyone: List[Int]) -> Result[Int]
  room_id = try insert_room(tx, Db.Value.Null, DIRECT, creator_id)
  for member in everyone
    try add_member(tx, room_id, member, "everything")
  end

  return ok(room_id)
end

def insert_room(tx: Db.Connection, name: Db.Value, kind: String, creator_id: Int) -> Result[Int]
  rows = try Db.query(
    tx,
    "insert into rooms (name, kind, creator_id) values (?, ?, ?) returning id",
    [name, Db.Value.Text(kind), Db.Value.Int(creator_id)],
  )

  return ok(int_of(rows[0], "id"))
end

# Only an active user can be put in a room, whatever the caller passed; one that is in already stays as they are.
def add_member(tx: Db.Connection, room_id: Int, user_id: Int, involvement: String) -> Result[Void]
  try Db.execute(
    tx,
    "insert into memberships (room_id, user_id, involvement) select ?, id, ? from users where id = ? and " +
    "status = #{Rails.ACTIVE} " +
    "on conflict (room_id, user_id) do nothing",
    [Db.Value.Int(room_id), Db.Value.Text(involvement), Db.Value.Int(user_id)],
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

  return Room(id: int_of(row, "id"), name: name, kind: kind, creator_id: int_of(row, "creator_id"))
end

def message_of(row: Db.Row) -> Message
  return Message(
    id: int_of(row, "id"),
    author: text_of(row, "author"),
    body: text_of(row, "body"),
    created_at: text_of(row, "created_at"),
  )
end

## Rooms, their members and their messages over the `rooms`, `memberships` and `messages` tables of the Rails schema
## (the body of a message is in `action_text_rich_texts`, and its plain text in `message_search_index`). These
## functions take an open connection and never see a request. A person is in a room when a `memberships` row says so,
## whatever the type of the room (`rooms.type`): an open room is one that every active person has a row in, which
## `create_open_in` and `grant_open_rooms` write. Every lookup for a person goes through that row, so a room of someone
## else is `none` exactly as a room that does not exist is, and a caller cannot tell them apart.

import Db from "pkg/db/db"
import HtmlSanitizer from "html_sanitizer"
import Rails from "repo/rails"
import {int_of, text_of} from "repo/rows"

## How many messages a page of a room holds.
export PAGE_SIZE = 40

## The types of room (`rooms.type`): every active person is in an open room, a closed room has a member list, and a
## direct room is between people and has no name of its own. `OPEN` is for this module only; the rest of the app never
## names it.
OPEN = Rails.ROOM_OPEN
export CLOSED = Rails.ROOM_CLOSED
export DIRECT = Rails.ROOM_DIRECT

## The label of the role of an account administrator, who may edit any closed room (`Auth.User.role` carries it; it is
## not the integer that `users.role` holds, which is `Rails.ADMINISTRATOR`).
export ADMINISTRATOR_ROLE_NAME = Rails.ADMINISTRATOR_NAME

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

# What a message is called when its author's row is gone (a database that Rails seeded can have one).
UNKNOWN_AUTHOR = "Unknown"

# The form of a timestamp in `<time datetime>`: ISO 8601, UTC, with milliseconds.
ISO = "%Y-%m-%dT%H:%M:%fZ"

## The select of a message as `stored_of` reads it, up to its tables and with no `where`: the author (or
## `UNKNOWN_AUTHOR`), the body that `action_text_rich_texts` holds, the time in the ISO form and `updated_at` as the
## column holds it. A page of a room and the search read their messages through it, so both show a message the same
## way.
export MESSAGE_SELECT = (
  "select messages.id, coalesce(users.name, '#{UNKNOWN_AUTHOR}') as author, " +
  "coalesce(rich_texts.body, '') as body, strftime('#{ISO}', messages.created_at) as created_at, " +
  "messages.updated_at as updated_at " +
  "from messages left join users on users.id = messages.creator_id " +
  "left join action_text_rich_texts rich_texts on rich_texts.record_type = '#{Rails.MESSAGE_RECORD}' " +
  "and rich_texts.record_id = messages.id and rich_texts.name = '#{Rails.BODY_NAME}'"
)

# A room as a person sees it. A direct room has no name, so it is called after the other people in it (the column is
# `others`, looked up only for a direct room, so an open room costs no subquery), and `memberships.involvement` is
# what the sidebar filters on. The names are joined in the order of the inner select, which the database keeps for
# `group_concat` in practice.
ROOM_COLUMNS = (
  "select rooms.id, rooms.type, rooms.name, rooms.creator_id, " +
  "case when rooms.type = '#{DIRECT}' then " +
  "(select group_concat(name, ', ') from (select users.name as name from memberships others " +
  "join users on users.id = others.user_id where others.room_id = rooms.id and others.user_id <> ? " +
  "order by users.name)) end as others " +
  "from memberships join rooms on rooms.id = memberships.room_id where memberships.user_id = ?"
)

## A room of a person. `name` is what to call it for them: its own name, or for a direct room the other people.
export struct Room
  id: Int
  name: String
  room_type: String
  creator_id: Int
end

## A person that a room form offers, an active user.
export struct Person
  id: Int
  name: String
end

## A message with the name of its author. `body` is HTML that `HtmlSanitizer.sanitize` has cleaned, so a view writes it
## with `<%== %>`. `created_at` is an ISO 8601 UTC instant with milliseconds (`2026-03-01T09:00:00.123Z`), made from
## the Rails form of the column, so that `<time datetime>` and the scripts that read it take it as UTC.
export struct Message
  id: Int
  author: String
  body: String
  created_at: String
end

## A message as the database holds it: the body is not cleaned yet, so `clean` must run before a view writes it. A page
## of a room hands these out, so that a view that has rendered the message before (`MessageCache`) can skip the
## cleaning. `updated_at` is the column as it is.
export struct Stored
  id: Int
  author: String
  body: String
  created_at: String
  updated_at: String
end

## A page of a room, oldest message first. `older` is the cursor of the page before it (`before=` of `page`), `none`
## when this one reaches the first message. `at_latest` is false for a page that was asked for with a cursor.
export struct Page
  messages: List[Stored]
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

## A message from a row of `MESSAGE_SELECT`, as it is stored.
export def stored_of(row: Db.Row) -> Stored
  return Stored(
    id: int_of(row, "id"),
    author: text_of(row, "author"),
    body: text_of(row, "body"),
    created_at: text_of(row, "created_at"),
    updated_at: text_of(row, "updated_at"),
  )
end

## The message with its body cleaned. Every body is cleaned on its way out, since a row that Rails wrote was never
## cleaned by this app; a body that `post` stored clean passes unchanged (`sanitize` is idempotent:
## test/html_sanitizer_test.agc).
export def clean(stored: Stored) -> Message
  return Message(
    id: stored.id,
    author: stored.author,
    body: HtmlSanitizer.sanitize(stored.body),
    created_at: stored.created_at,
  )
end

## A message from a row of `MESSAGE_SELECT`, with its body cleaned.
export def message_of(row: Db.Row) -> Message
  return clean(stored_of(row))
end

## The rooms that the person shows in their sidebar: every room they are in, except the ones they set to invisible,
## by name.
export def visible(conn: Db.Connection, user_id: Int) -> Result[List[Room]]
  rows = try Db.query(
    conn,
    "select * from (#{ROOM_COLUMNS} and memberships.involvement <> '#{Rails.INVISIBLE}') " +
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
  room_id = try insert_room(tx, Db.Value.Text(name), OPEN, creator_id)
  try Db.execute(
    tx,
    "insert into memberships (room_id, user_id, created_at, updated_at) " +
    "select ?, id, #{NOW}, #{NOW} from users where status = #{Rails.ACTIVE}",
    [Db.Value.Int(room_id)],
  )

  return ok(room_id)
end

## Puts the person in every open room, for whoever makes a user after the rooms exist (an invitation). A room that
## they are in already is left as it is.
export def grant_open_rooms(conn: Db.Connection, user_id: Int) -> Result[Void]
  try Db.execute(
    conn,
    "insert into memberships (room_id, user_id, created_at, updated_at) " +
    "select id, ?, #{NOW}, #{NOW} from rooms where type = '#{OPEN}' on conflict (room_id, user_id) do nothing",
    [Db.Value.Int(user_id)],
  )

  return ok()
end

## True when the person may change the room: it is a closed room and they made it or are an account administrator, as
## upstream lets only the creator and an administrator administer a room. Being in the room is not enough.
export def editable?(room: Room, user_id: Int, role: String) -> Bool
  return room.room_type == CLOSED and (room.creator_id == user_id or role == ADMINISTRATOR_ROLE_NAME)
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
## first, by `created_at` as Rails does: the rows of a database that Rails seeded are not in the order of their time,
## so the id says nothing about it. Messages that share an instant go by `id`, so a page and the one before it neither
## repeat nor skip one; a `before` that is no message of this room (unknown, or of another room) gives an empty page.
## It reads one more than a page, to know whether there is an older page without a count.
export def page(conn: Db.Connection, room_id: Int, before: Optional[Int]) -> Result[Page]
  params = [Db.Value.Int(room_id)]
  cursor = ""
  case before
    some(anchor) ->
      cursor = (
        "and (messages.created_at, messages.id) < " +
        "(select anchor.created_at, anchor.id from messages anchor where anchor.id = ? " +
        "and anchor.room_id = messages.room_id)"
      )

      params = params.push(Db.Value.Int(anchor))
    none -> cursor = ""
  end

  rows = try Db.query(
    conn,
    "#{MESSAGE_SELECT} where messages.room_id = ? #{cursor} " +
    "order by messages.created_at desc, messages.id desc limit ?",
    params.push(Db.Value.Int(PAGE_SIZE + 1)),
  )

  shown = rows.take(PAGE_SIZE).map do |row| stored_of(row) end
  older: Optional[Int] = none
  if rows.size > PAGE_SIZE
    older = some(shown.last.id)
  end

  return ok(Page(messages: shown.reverse, older: older, at_latest: before.none?))
end

## Stores a message of the person in the room, which the caller has checked they are in, and gives it as it is stored
## (`some`), or `none` when the person is not active any more: the insert itself needs an active person, so a
## deactivation that came after the sign-in check (the request may have waited for a connection) stores nothing.
## `html` is the body as the editor sent it. It is cleaned here by `HtmlSanitizer.sanitize` before the transaction
## begins, so the work of the sanitizer does not hold the write lock of the database that the other writers wait for,
## and goes in `action_text_rich_texts`; the plain text of it goes in `message_search_index` with the id of the message
## as its rowid. The rows are written in one transaction, so the audits of the harness (and a reader of the database)
## never see a message without its body or its index row. As Rails does (`belongs_to :room, touch: true` and
## `Room#receive`), the room is touched and the people in it who are not the author, who did not set the room to
## invisible and are not connected get `unread_at`. `client_message_id` is what the browser made for the message; it is
## stored, and there is no check on it (Rails has none): a second post with the same one is a second message.
export def post(
  conn: Db.Connection,
  room_id: Int,
  user_id: Int,
  client_message_id: String,
  html: String,
) -> Result[Optional[Message]]
  body = HtmlSanitizer.sanitize(html)
  text = HtmlSanitizer.plain_text_of_clean(body)
  return Db.transaction(conn) do |tx| post_in(tx, room_id, user_id, client_message_id, body, text) end
end

def post_in(
  tx: Db.Connection,
  room_id: Int,
  user_id: Int,
  client_message_id: String,
  body: String,
  text: String,
) -> Result[Optional[Message]]
  rows = try Db.query(
    tx,
    "insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) " +
    "select ?, ?, ?, #{NOW}, #{NOW} where exists (select 1 from users where id = ? and status = #{Rails.ACTIVE}) " +
    "returning id, #{iso("created_at")} as created_at, " +
    "coalesce((select name from users where id = messages.creator_id), '#{UNKNOWN_AUTHOR}') as author",
    [Db.Value.Int(room_id), Db.Value.Int(user_id), Db.Value.Text(client_message_id), Db.Value.Int(user_id)],
  )

  if rows.empty?
    return ok(none)
  end

  message_id = Db.Value.Int(int_of(rows[0], "id"))
  try Db.execute(
    tx,
    "insert into action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at) " +
    "values ('#{Rails.MESSAGE_RECORD}', ?, '#{Rails.BODY_NAME}', ?, #{NOW}, #{NOW})",
    [message_id, Db.Value.Text(body)],
  )

  try Db.execute(tx, "insert into message_search_index (rowid, body) values (?, ?)", [message_id, Db.Value.Text(text)])
  try receive(tx, room_id, user_id, message_id)
  return ok(
    some(
      Message(
        id: int_of(rows[0], "id"),
        author: text_of(rows[0], "author"),
        body: body,
        created_at: text_of(rows[0], "created_at"),
      ),
    ),
  )
end

# What a message does to its room, as `Message` and `Room#receive` of Rails do: the room is touched, and each member
# who is not the author, has not set the room to invisible and is not connected now (`connected_at` older than
# `Rails.CONNECTION_TTL_SECONDS`, or none) has the room unread since the time of the message. `Room#receive` is an
# `update_all`, which does not touch `memberships.updated_at`, so neither does this.
def receive(tx: Db.Connection, room_id: Int, user_id: Int, message_id: Db.Value) -> Result[Void]
  try Db.execute(tx, "update rooms set updated_at = #{NOW} where id = ?", [Db.Value.Int(room_id)])
  try Db.execute(
    tx,
    "update memberships set unread_at = (select created_at from messages where id = ?) " +
    "where room_id = ? and user_id <> ? and involvement <> '#{Rails.INVISIBLE}' and (connected_at is null or " +
    "connected_at < strftime('#{Rails.STAMP}', 'now', '-#{Rails.CONNECTION_TTL_SECONDS} seconds'))",
    [message_id, Db.Value.Int(room_id), Db.Value.Int(user_id)],
  )

  return ok()
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
    "update rooms set name = ?, updated_at = #{NOW} where id = ? and type = '#{CLOSED}' " +
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
    "select rooms.id from rooms where rooms.type = '#{DIRECT}' " +
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

def insert_room(tx: Db.Connection, name: Db.Value, room_type: String, creator_id: Int) -> Result[Int]
  rows = try Db.query(
    tx,
    "insert into rooms (name, type, creator_id, created_at, updated_at) values (?, ?, ?, #{NOW}, #{NOW}) returning id",
    [name, Db.Value.Text(room_type), Db.Value.Int(creator_id)],
  )

  return ok(int_of(rows[0], "id"))
end

# Only an active user can be put in a room, whatever the caller passed; one that is in already stays as they are.
def add_member(tx: Db.Connection, room_id: Int, user_id: Int, involvement: String) -> Result[Void]
  try Db.execute(
    tx,
    "insert into memberships (room_id, user_id, involvement, created_at, updated_at) " +
    "select ?, id, ?, #{NOW}, #{NOW} from users where id = ? and status = #{Rails.ACTIVE} " +
    "on conflict (room_id, user_id) do nothing",
    [Db.Value.Int(room_id), Db.Value.Text(involvement), Db.Value.Int(user_id)],
  )

  return ok()
end

# The SQL for the ISO 8601 UTC form of a timestamp column, which a page writes in `<time datetime>`.
def iso(column: String) -> String
  return "strftime('#{ISO}', #{column})"
end

def room_of(row: Db.Row) -> Room
  room_type = text_of(row, "type")
  name = text_of(row, "name")
  if room_type == DIRECT
    name = text_of(row, "others")
  end

  if name.empty?
    name = NO_NAME
  end

  return Room(id: int_of(row, "id"), name: name, room_type: room_type, creator_id: int_of(row, "creator_id"))
end

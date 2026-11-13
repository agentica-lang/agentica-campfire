## Boosts over the `boosts` table of the Rails schema (`Boost` of Rails): a short reaction, an emoji or a few words,
## that a person in a room puts under a message. Only the booster takes a boost away. A person reaches a message
## through the `memberships` row of its room, whatever the kind of room (`User#reachable_messages`), so a message of a
## room the person is not in is `none`, exactly as a message that does not exist is, and a caller cannot tell them
## apart. A boost touches its message and the room, as `belongs_to :message, touch: true` does, so the refresh of a
## room and the cache of rendered messages see it. These functions take an open connection and never see a request.
##
## `Rooms` reads the boosts of the messages it gives out in the same query as the messages (`COLUMN`), so this module
## imports nothing of `Rooms`.

import Db from "pkg/db/db"
import Rails from "repo/rails"
import {int_of, text_of} from "repo/rows"

## The longest boost, in characters (`boosts.content` is `varchar(16)` in the schema; SQLite does not enforce it, so
## this module does).
MAX_CONTENT_LENGTH = 16
## The column of a message query (one that has `messages` in its `from`) that holds the boosts of the message, as a
## JSON array in the order Rails shows them (`ordered`: by time, then id) for `parse`. The inner select fixes the order
## that `json_group_array` reads its rows in. A message with no boost gets `[]`, which `parse` answers without
## decoding.
COLUMN = (
  "(select json_group_array(json_object('id', one.id, 'booster_id', one.booster_id, " +
  "'booster', coalesce(people.name, '#{UNKNOWN_BOOSTER}'), 'content', one.content, 'created_at', one.created_at)) " +
  "from (select id, booster_id, content, #{ISO_STAMP} as created_at from boosts where message_id = messages.id " +
  "order by boosts.created_at, id) one " +
  "left join users people on people.id = one.booster_id) as boosts"
)

## A boost with the name of its booster (`booster_id` is who made it). `created_at` is an ISO 8601 UTC instant with
## milliseconds.
struct Boost
  id: Int
  booster_id: Int
  booster: String
  content: String
  created_at: String
end

## A message that a person can reach, and the room it is in.
struct Reach
  message_id: Int
  room_id: Int
end

## What is wrong with the text of a boost, or "". The caller strips it first.
def content_problem(content: String) -> String
  return "A boost is 1 to #{MAX_CONTENT_LENGTH} characters" if content.empty? or content.length > MAX_CONTENT_LENGTH

  ""
end

## The boosts that the column `COLUMN` of a message query holds, oldest first.
def parse(text: String) -> List[Boost]
  return [] if text == "[]" or text.empty?

  # SQLite wrote this text with its JSON functions, so it decodes; a column that is not that shows no boosts.
  listing = JSON.decode("{\"boosts\":#{text}}", Listing)
  return [] if not listing.ok?

  listing.unwrap!.boosts
end

## The message of the person's rooms with this id, or `none` for a room the person is not in and for a message that
## does not exist.
def reach(conn: Db.Connection, user_id: Int, message_id: Int) -> Result[Optional[Reach]]
  rows = try Db.query(
    conn,
    "select messages.id, messages.room_id from messages " +
    "join memberships on memberships.room_id = messages.room_id and memberships.user_id = ? where messages.id = ?",
    [Db.Value.Int(user_id), Db.Value.Int(message_id)],
  )

  return ok(none) if rows.empty?

  ok(some(Reach(message_id: int_of(rows[0], "id"), room_id: int_of(rows[0], "room_id"))))
end

## The boosts of a message, oldest first.
def of_message(conn: Db.Connection, message_id: Int) -> Result[List[Boost]]
  rows = try Db.query(
    conn,
    "select boosts.id, boosts.booster_id, boosts.content, #{ISO_STAMP} as created_at, " +
    "coalesce(users.name, '#{UNKNOWN_BOOSTER}') as booster " +
    "from boosts left join users on users.id = boosts.booster_id where boosts.message_id = ? " +
    "order by boosts.created_at, boosts.id",
    [Db.Value.Int(message_id)],
  )

  ok(rows.map do |row| boost_of(row) end)
end

## Stores a boost of the person on the message and gives it, or `none` when the person is not active, is not in the
## room of the message, or the message is gone: the insert itself looks at all three, so a change that came after the
## caller's check stores nothing. The message and its room are touched in the same transaction. `content` is checked
## by the caller (`content_problem`).
def add(conn: Db.Connection, user_id: Int, message_id: Int, content: String) -> Result[Optional[Boost]]
  Db.transaction(conn) do |tx| add_in(tx, user_id, message_id, content) end
end

## Takes the person's own boost off the message. It gives false, and changes nothing, for a boost of somebody else
## (an administrator's right over messages does not reach boosts, as `find_by!(booster: Current.user)` in Rails), a
## boost of another message, one that is gone, and a person who is no longer active or in the room. The message and its
## room are touched in the same transaction.
def remove(conn: Db.Connection, user_id: Int, message_id: Int, boost_id: Int) -> Result[Bool]
  Db.transaction(conn) do |tx| remove_in(tx, user_id, message_id, boost_id) end
end

private

# What a boost is called after, when its booster's row is gone (a database that Rails seeded can have one).
UNKNOWN_BOOSTER = "Unknown"
NOW = Rails.NOW
# A time of the table as an ISO 8601 instant in UTC with milliseconds, which is how the API of the bots writes it.
ISO_STAMP = "strftime('%Y-%m-%dT%H:%M:%fZ', boosts.created_at)"

# `JSON.decode` takes a struct, so the array is decoded as the field of one.
struct Listing
  boosts: List[Boost]
end

# Whether the person is active and in the room of the message, as SQL for the `where` of a write, with its two
# parameters (`message_id`, `user_id`) given by the caller in that order.
def allowed_sql() -> String
  (
    "exists (select 1 from memberships join messages on messages.room_id = memberships.room_id " +
    "where messages.id = ? and memberships.user_id = ?) " +
    "and exists (select 1 from users where users.id = ? and users.status = #{Rails.ACTIVE})"
  )
end

def add_in(tx: Db.Connection, user_id: Int, message_id: Int, content: String) -> Result[Optional[Boost]]
  rows = try Db.query(
    tx,
    "insert into boosts (booster_id, content, message_id, created_at, updated_at) " +
    "select ?, ?, messages.id, #{NOW}, #{NOW} from messages where messages.id = ? and #{allowed_sql()} " +
    "returning id, booster_id, content, #{ISO_STAMP} as created_at, " +
    "coalesce((select name from users where id = boosts.booster_id), '#{UNKNOWN_BOOSTER}') as booster",
    [
      Db.Value.Int(user_id),
      Db.Value.Text(content),
      Db.Value.Int(message_id),
      Db.Value.Int(message_id),
      Db.Value.Int(user_id),
      Db.Value.Int(user_id),
    ],
  )

  return ok(none) if rows.empty?

  try touch(tx, message_id)
  ok(some(boost_of(rows[0])))
end

def remove_in(tx: Db.Connection, user_id: Int, message_id: Int, boost_id: Int) -> Result[Bool]
  changed = try Db.execute(
    tx,
    "delete from boosts where id = ? and message_id = ? and booster_id = ? and #{allowed_sql()}",
    [
      Db.Value.Int(boost_id),
      Db.Value.Int(message_id),
      Db.Value.Int(user_id),
      Db.Value.Int(message_id),
      Db.Value.Int(user_id),
      Db.Value.Int(user_id),
    ],
  )

  return ok(false) if changed != 1

  try touch(tx, message_id)
  ok(true)
end

# `touch: true` of Rails, twice over: the message, and the room through it.
def touch(tx: Db.Connection, message_id: Int) -> Result[Void]
  id = Db.Value.Int(message_id)
  try Db.execute(tx, "update messages set updated_at = #{NOW} where id = ?", [id])
  try Db.execute(
    tx,
    "update rooms set updated_at = #{NOW} where id = (select room_id from messages where id = ?)",
    [id],
  )

  ok()
end

def boost_of(row: Db.Row) -> Boost
  Boost(
    id: int_of(row, "id"),
    booster_id: int_of(row, "booster_id"),
    booster: text_of(row, "booster"),
    content: text_of(row, "content"),
    created_at: text_of(row, "created_at"),
  )
end

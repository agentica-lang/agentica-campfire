## The search of messages and the list of recent searches, over `message_search_index` (a standalone FTS5 table with the
## porter tokenizer, `rowid` the id of the message) and `searches` of the Rails schema. What a person types is words:
## it is turned into a search of those words and never run as FTS5 syntax, whose `AND`, `OR`, `NOT`, `NEAR`, `*`, `-`,
## `col:` and an odd quote would otherwise make a query fail.

import Regex from "std/regex"
import Db from "pkg/db/db"
import Rails from "repo/rails"
import Rooms from "rooms"
import {text_of} from "repo/rows"

## The most messages that a search gives.
export MAX_MESSAGES = 100

## How many recent searches a person keeps (`trim_recent_searches` of `Search`).
export RECENT = 10

## The most words of a query that a search uses: the rest is dropped, so a long query string cannot make thousands of
## phrases for the index. Rails has no limit; nobody types more.
export MAX_WORDS = 50

## The longest query that is remembered, in characters. Rails has no limit; this one keeps a table of tens of kilobytes
## out of reach of whoever posts one.
export MAX_QUERY_LENGTH = 200

# What `params[:q].gsub(/[^[:word:]]/, " ")` of `SearchesController` removes. `[:word:]` is every letter, mark, number
# and connector of Unicode; here, every character that is not ASCII counts as a word character, so a word in any
# script stays whole and the tokenizer of the index (which knows Unicode) decides what is a letter. A stray symbol
# that this keeps goes inside quotes and is only text there.
NOT_WORD = /[^0-9A-Za-z_\x{80}-\x{10FFFF}]+/

## The words of what a person typed, with one space between them: `Coffee, & tea!` is `Coffee tea`. Everything that is
## not a letter, digit or `_` is a separator, as `SearchesController#query` does. At most `MAX_WORDS` are kept. It is "" when nothing is left.
export def words(typed: String) -> String
  spaced = Regex.replace(typed, NOT_WORD, " ")
  return spaced.unwrap_or("").strip.split(" ").take(MAX_WORDS).join(" ")
end

## The FTS5 expression for `query` (the result of `words`): each word in double quotes, so FTS5 reads it as text and
## not as an operator, and a quote inside a word is doubled (`Message.match_terms` of Rails). Words are joined by a
## space, which FTS5 reads as `AND`. `words` has no quote left, so the doubling is a second guard.
export def match(query: String) -> String
  parts = query.split(" ").select do |word| not word.empty? end
  return parts.map do |word| "\"#{word.replace("\"", "\"\"")}\"" end.join(" ")
end

## The newest `MAX_MESSAGES` messages of the rooms that the person is in (any involvement) that match `query`, oldest
## first, which is how the page shows them. `query` is `words` of what was typed: with no word there is nothing to
## search for, and no message is read. The order is the index's `rowid`, which is the message id, so SQLite can read the
## index from its newest end, but matches in rooms the person is not in are read and skipped.
export def messages(conn: Db.Connection, user_id: Int, query: String) -> Result[List[Rooms.Message]]
  if query.empty?
    return ok([])
  end

  rows = try Db.query(
    conn,
    "#{Rooms.MESSAGE_SELECT} join message_search_index idx on idx.rowid = messages.id " +
    "where idx.body match ? and messages.room_id in (select room_id from memberships where user_id = ?) " +
    "order by idx.rowid desc limit ?",
    [Db.Value.Text(match(query)), Db.Value.Int(user_id), Db.Value.Int(MAX_MESSAGES)],
  )

  return ok(rows.map do |row| Rooms.message_of(row) end.reverse)
end

## Remembers `query` (the result of `words`) for the person: one that they searched for before moves to the front, and
## only the `RECENT` last are kept. The three statements are one transaction, so two searches at once do not keep more.
export def record(conn: Db.Connection, user_id: Int, query: String) -> Result[Void]
  return Db.transaction(conn) do |tx| record_in(tx, user_id, query) end
end

## The queries that the person searched for, the latest first.
export def recent(conn: Db.Connection, user_id: Int) -> Result[List[String]]
  rows = try Db.query(
    conn,
    "select query from searches where user_id = ? order by updated_at desc, id desc limit ?",
    [Db.Value.Int(user_id), Db.Value.Int(RECENT)],
  )

  return ok(rows.map do |row| text_of(row, "query") end)
end

## Forgets every recent search of the person and no one else's (`Current.user.searches.destroy_all` of
## `SearchesController#clear`). It gives how many it removed.
export def clear(conn: Db.Connection, user_id: Int) -> Result[Int]
  return Db.execute(conn, "delete from searches where user_id = ?", [Db.Value.Int(user_id)])
end

def record_in(tx: Db.Connection, user_id: Int, query: String) -> Result[Void]
  touched = try Db.execute(
    tx,
    "update searches set updated_at = #{Rails.NOW} where user_id = ? and query = ?",
    [Db.Value.Int(user_id), Db.Value.Text(query)],
  )

  if touched == 0
    try Db.execute(
      tx,
      "insert into searches (user_id, query, created_at, updated_at) values (?, ?, #{Rails.NOW}, #{Rails.NOW})",
      [Db.Value.Int(user_id), Db.Value.Text(query)],
    )
  end

  try Db.execute(
    tx,
    "delete from searches where user_id = ? and id not in " +
    "(select id from searches where user_id = ? order by updated_at desc, id desc limit ?)",
    [Db.Value.Int(user_id), Db.Value.Int(user_id), Db.Value.Int(RECENT)],
  )

  return ok()
end

## The database of the app: SQLite, opened from a url, with its migrations run.

import Db from "pkg/db/db"
import DbPool from "pkg/db/db_pool"
import Migrate from "pkg/db/migrate"
import Migrations from "migrations"
import VersionReader from "version_reader"
import {int_of, text_of} from "rows"

# How long `close_pool` lets the running requests finish.
CLOSE_MS = 1_000

## The connections of the app, opened once at the start (see `open_pool`).
export type Pool = DbPool.Pool

## The one connection that watches the database for changes (see `open_observer`).
export type Observer = VersionReader.Reader

## The schema version of a database after `migrate`, and the migrations that this call applied (none when the database
## was already up to date). `rails` is a database that Rails made, which `migrate` left as it was: its version is the
## last one that Rails recorded (`20251212154340` for the schema of Campfire at 90b3300), not one of this app's.
export struct Schema
  version: Int
  applied: List[Int]
  rails: Bool
end

## Opens the database at `url` (see agentica-db for the url of SQLite), runs the migrations that it has not seen and
## closes it again. The connection belongs to the task that opened it, so the app does not keep this one. A database
## that Rails made (it has `ar_internal_metadata`, which Rails writes and this app never does) is the schema of the
## app already, so it is opened as it is and no migration runs, not even a history table: the only thing added is the
## table of the password resets, which Rails has not (`Migrations.extensions`). An `error` says what failed, and stops
## the start.
export def migrate(url: String) -> Result[Schema]
  conn = try Db.open(url)
  migrated = migrate_open(conn)
  Db.close(conn)
  migrated
end

## Opens `size` connections to the database at `url` (0 takes the size of the database, 4 for SQLite) and starts the
## pool. A caller that finds all of them busy waits up to `checkout_ms`, then gets a `pool error: checkout timed out`
## that `timeout?` tells. The connections belong to the task that calls this, so it must live as long as the app does.
## The migrations ran before (`migrate`), and the url is a file: a `sqlite::memory:` database would be one empty
## database per connection. An `error` says what failed (a url that does not open), and stops the start.
export def open_pool(url: String, size: Int, checkout_ms: Int) -> Result[Pool]
  DbPool.start(DbPool.Options(url: url, size: size, checkout_ms: checkout_ms))
end

## Closes the pool: the requests that run finish first (for up to a second), and the rest is turned away.
export def close_pool(pool: Pool) -> Void
  DbPool.close(pool, CLOSE_MS)
end

## Opens the observer: a read-only connection of its own to the database at `url`, which `version` reads. It is apart
## from the pool of the requests because `PRAGMA data_version` changes only for the commits of the other connections:
## on a connection that serves requests it would miss its own writes. See `version_reader.agc` for how the schedulers
## share it. As for `open_pool`, the connection belongs to the task that calls this, which must live as long as the
## app does. An `error` says what failed.
export def open_observer(url: String) -> Result[Observer] = VersionReader.open(url)

## Closes the observer, once nothing reads it any more.
export def close_observer(observer: Observer) -> Void
  VersionReader.close(observer)
end

## A text that is the same for two calls only when no commit was made to the database in between, by any connection of
## any program (the app itself, a Rails app, the `sqlite3` tool): the `data_version` of the observer. A change of the
## schema or of a table that nothing reads is a change too: that only costs a page that is made again. An `error`
## means that nothing is known, so the caller must not trust or keep anything it saw before.
export def version(observer: Observer) -> Result[String] = VersionReader.version(observer)

## Runs `body` with a connection of the pool and gives its result: a request takes one connection, does all its work
## on it and gives it back, whatever `body` gives (a transaction it left open is rolled back). The block runs in a task
## of the pool, not in the task of the request.
export def with_connection[R](pool: Pool, body: Fn[Db.Connection, Result[R]]) -> Result[R] = DbPool.with(pool, body)

## True for the message of a failure that means the database is busy, not broken: no free connection within
## `checkout_ms`, more callers in line than the pool takes, a pool that is closing, a block or a statement that ran too
## long (`DbPool.timeout?`), and SQLite's `database is locked` (error 5) once its `busy_timeout` is over. The app
## answers those with a 503 instead of a 500.
export def busy?(message: String) -> Bool
  (
    DbPool.timeout?(message) or
    message.include?("pool error: queue full") or
    message.include?("pool error: closed") or
    message.include?("sqlite error 5:")
  )
end

# The keys of the schema (a message needs its room and its author) need foreign keys on, and a `foreign_keys=off` in
# the url turns them off without a word. A Rails database has them on in the app too.
def migrate_open(conn: Db.Connection) -> Result[Schema]
  rows = try Db.query(conn, "pragma foreign_keys", [])
  if not rows.any? do |row| on?(row.get("foreign_keys", Db.Value.Null)) end
    return error("database error: foreign keys are off, so remove foreign_keys=off from the url")
  end

  from_rails = try rails_made?(conn)
  if from_rails
    try check_rails_columns(conn)
    try Db.transaction(conn) do |tx| add_extensions(tx) end
    version = try rails_version(conn)
    return ok(Schema(version: version, applied: [], rails: true))
  end

  earlier = try earlier_version?(conn)
  if earlier
    return error(
      "database error: this database was made by an earlier version of the app, whose migration history was " +
      "rewritten before the first release: delete the database file and start again",
    )
  end

  applied = try Migrate.up(conn, Migrations.all(), Migrations.HISTORY_TABLE)
  ok(Schema(version: Migrations.latest(), applied: applied, rails: false))
end

# The columns of the Rails schema that the app reads or writes. A database that has `ar_internal_metadata` is trusted
# to be the schema of Campfire at 90b3300 and is not migrated, so a start checks these, and a database of some other
# Rails app, or an older Campfire, stops it with the name of what is missing, instead of failing in a request.
def needed_columns() -> Map[String, List[String]]
  {
    "accounts": ["id", "name", "join_code", "singleton_guard", "created_at", "updated_at"],
    "users": [
      "id",
      "name",
      "email_address",
      "password_digest",
      "bot_token",
      "role",
      "status",
      "created_at",
      "updated_at",
    ],
    "sessions": ["id", "user_id", "token", "user_agent", "ip_address", "last_active_at", "created_at", "updated_at"],
    "rooms": ["id", "name", "type", "creator_id", "created_at", "updated_at"],
    "memberships": [
      "id",
      "room_id",
      "user_id",
      "involvement",
      "unread_at",
      "connected_at",
      "connections",
      "created_at",
      "updated_at",
    ],
    "messages": ["id", "room_id", "creator_id", "client_message_id", "created_at", "updated_at"],
    "boosts": ["id", "booster_id", "content", "message_id", "created_at", "updated_at"],
    "action_text_rich_texts": ["id", "record_type", "record_id", "name", "body", "created_at", "updated_at"],
    # The standalone FTS5 table (`pragma table_info` lists its one column, not `rowid`).
    "message_search_index": ["body"],
  }
end

def check_rails_columns(conn: Db.Connection) -> Result[Void]
  needed = needed_columns()
  for table in needed.keys
    rows = try Db.query(conn, "pragma table_info(#{table})", [])
    present = rows.map do |row| text_of(row, "name") end
    for column in needed.get(table, [])
      if not present.include?(column)
        return error("database error: the database made by Rails has no column #{table}.#{column}")
      end
    end
  end

  ok()
end

# The tables that the app has and Rails has not. They are not a migration: there is no history to record, and the
# statements are safe to run at every start.
def add_extensions(tx: Db.Connection) -> Result[Void]
  for sql in Migrations.extensions()
    try Db.execute(tx, sql, [])
  end

  ok()
end

# What the app made before its history was rewritten to the Rails schema: it has `schema_migrations` (the default
# table of `Migrate`), and neither `ar_internal_metadata` nor the table of the history now. Its tables are not the
# Rails ones and no migration turns them into those.
def earlier_version?(conn: Db.Connection) -> Result[Bool]
  rows = try Db.query(
    conn,
    "select name from sqlite_master where type = 'table' and name in ('schema_migrations', ?)",
    [Db.Value.Text(Migrations.HISTORY_TABLE)],
  )

  names = rows.map do |row| text_of(row, "name") end
  ok(names.include?("schema_migrations") and not names.include?(Migrations.HISTORY_TABLE))
end

# `ar_internal_metadata` is the table that Active Record makes for itself in every database it creates, with the
# environment in it. A database that this app made never has it, so a start never takes its own database for Rails'.
def rails_made?(conn: Db.Connection) -> Result[Bool]
  rows = try Db.query(
    conn,
    "select count(*) as total from sqlite_master where type = 'table' and name = 'ar_internal_metadata'",
    [],
  )

  ok(int_of(rows[0], "total") > 0)
end

# The newest `schema_migrations.version` (a timestamp, kept as text), or 0 when there is none.
def rails_version(conn: Db.Connection) -> Result[Int]
  rows = try Db.query(conn, "select max(cast(version as integer)) as newest from schema_migrations", [])
  newest = int_of(rows[0], "newest")
  return ok(0) if newest < 0

  ok(newest)
end

def on?(value: Db.Value) -> Bool
  case value
    Db.Value.Int(flag) -> flag == 1
    _ -> false
  end
end

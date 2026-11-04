## The database of the app: SQLite, opened from a url, with its migrations run.

import Db from "pkg/db/db"
import DbPool from "pkg/db/db_pool"
import Migrate from "pkg/db/migrate"
import Migrations from "migrations"
import {int_of} from "rows"

# How long `close_pool` lets the running requests finish.
CLOSE_MS = 1_000

## The connections of the app, opened once at the start (see `open_pool`).
export type Pool = DbPool.Pool

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
  return migrated
end

## Opens `size` connections to the database at `url` (0 takes the size of the database, 4 for SQLite) and starts the
## pool. A caller that finds all of them busy waits up to `checkout_ms`, then gets a `pool error: checkout timed out`
## that `timeout?` tells. The connections belong to the task that calls this, so it must live as long as the app does.
## The migrations ran before (`migrate`), and the url is a file: a `sqlite::memory:` database would be one empty
## database per connection. An `error` says what failed (a url that does not open), and stops the start.
export def open_pool(url: String, size: Int, checkout_ms: Int) -> Result[Pool]
  return DbPool.start(DbPool.Options(url: url, size: size, checkout_ms: checkout_ms))
end

## Closes the pool: the requests that run finish first (for up to a second), and the rest is turned away.
export def close_pool(pool: Pool) -> Void
  DbPool.close(pool, CLOSE_MS)
end

## Runs `body` with a connection of the pool and gives its result: a request takes one connection, does all its work
## on it and gives it back, whatever `body` gives (a transaction it left open is rolled back). The block runs in a task
## of the pool, not in the task of the request.
export def with_connection[R](pool: Pool, body: Fn[Db.Connection, Result[R]]) -> Result[R]
  return DbPool.with(pool, body)
end

## True for the message of a failure that means the database is busy, not broken: no free connection within
## `checkout_ms`, more callers in line than the pool takes, a pool that is closing, a block or a statement that ran too
## long (`DbPool.timeout?`), and SQLite's `database is locked` (error 5) once its `busy_timeout` is over. The app
## answers those with a 503 instead of a 500.
export def busy?(message: String) -> Bool
  return (
    DbPool.timeout?(message) or
    message.include?("pool error: queue full") or
    message.include?("pool error: closed") or
    message.include?("sqlite error 5:")
  )
end

# The cascades of the schema (a room takes its messages, and through them the search index) need foreign keys on, and
# a `foreign_keys=off` in the url turns them off without a word. A Rails database has them on in the app too.
def migrate_open(conn: Db.Connection) -> Result[Schema]
  rows = try Db.query(conn, "pragma foreign_keys", [])
  if not rows.any? do |row| on?(row.get("foreign_keys", Db.Value.Null)) end
    return error("database error: foreign keys are off, so remove foreign_keys=off from the url")
  end

  from_rails = try rails_made?(conn)
  if from_rails
    try Db.transaction(conn) do |tx| add_extensions(tx) end
    version = try rails_version(conn)
    return ok(Schema(version: version, applied: [], rails: true))
  end

  applied = try Migrate.up(conn, Migrations.all(), Migrations.HISTORY_TABLE)
  return ok(Schema(version: Migrations.latest(), applied: applied, rails: false))
end

# The tables that the app has and Rails has not. They are not a migration: there is no history to record, and the
# statements are safe to run at every start.
def add_extensions(tx: Db.Connection) -> Result[Void]
  for sql in Migrations.extensions()
    try Db.execute(tx, sql, [])
  end

  return ok()
end

# `ar_internal_metadata` is the table that Active Record makes for itself in every database it creates, with the
# environment in it. A database that this app made never has it, so a start never takes its own database for Rails'.
def rails_made?(conn: Db.Connection) -> Result[Bool]
  rows = try Db.query(
    conn,
    "select count(*) as total from sqlite_master where type = 'table' and name = 'ar_internal_metadata'",
    [],
  )

  return ok(int_of(rows[0], "total") > 0)
end

# The newest `schema_migrations.version` (a timestamp, kept as text), or 0 when there is none.
def rails_version(conn: Db.Connection) -> Result[Int]
  rows = try Db.query(conn, "select max(cast(version as integer)) as newest from schema_migrations", [])
  newest = int_of(rows[0], "newest")
  if newest < 0
    return ok(0)
  end

  return ok(newest)
end

def on?(value: Db.Value) -> Bool
  case value
    Db.Value.Int(flag) -> return flag == 1
    _ -> return false
  end
end

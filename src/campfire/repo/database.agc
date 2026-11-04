## The database of the app: SQLite, opened from a url, with its migrations run.

import Db from "pkg/db/db"
import DbPool from "pkg/db/db_pool"
import Migrate from "pkg/db/migrate"
import Migrations from "migrations"

# How long `close_pool` lets the running requests finish.
CLOSE_MS = 1_000

## The connections of the app, opened once at the start (see `open_pool`).
export type Pool = DbPool.Pool

## The schema version of a database after `migrate`, and the migrations that this call applied (none when the database
## was already up to date).
export struct Schema
  version: Int
  applied: List[Int]
end

## Opens the database at `url` (see agentica-db for the url of SQLite), runs the migrations that it has not seen and
## closes it again. The connection belongs to the task that opened it, so the app does not keep this one. An `error`
## says what failed, and stops the start.
export def migrate(url: String) -> Result[Schema]
  conn = try Db.open(url)
  migrated = migrate_open(conn)
  Db.close(conn)
  applied = try migrated
  return ok(Schema(version: Migrations.latest(), applied: applied))
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

## True for the message of a failure that ran out of time: no free connection within `checkout_ms`, a block that ran
## too long, or a statement over its `timeout_ms`. The app answers those with a 503 instead of a 500.
export def timeout?(message: String) -> Bool
  return DbPool.timeout?(message)
end

# The cascades of the schema (a room takes its messages, and through them the search index) need foreign keys on, and
# a `foreign_keys=off` in the url turns them off without a word.
def migrate_open(conn: Db.Connection) -> Result[List[Int]]
  rows = try Db.query(conn, "pragma foreign_keys", [])
  if not rows.any? do |row| on?(row.get("foreign_keys", Db.Value.Null)) end
    return error("database error: foreign keys are off, so remove foreign_keys=off from the url")
  end

  return Migrate.up(conn, Migrations.all())
end

def on?(value: Db.Value) -> Bool
  case value
    Db.Value.Int(flag) -> return flag == 1
    _ -> return false
  end
end

## The database of the app: SQLite, opened from a url, with its migrations run.

import Db from "pkg/db/db"
import Migrate from "pkg/db/migrate"
import Migrations from "migrations"

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

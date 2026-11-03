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
  migrated = Migrate.up(conn, Migrations.all())
  Db.close(conn)
  applied = try migrated
  return ok(Schema(version: Migrations.latest(), applied: applied))
end

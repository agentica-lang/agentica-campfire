## The steps of the features. The program of `fixtures/server.agc` serves the app on 127.0.0.1 and a free port on the
## database that its first input line names, and the steps talk to it with the HTTP client of `std/http`. The steps of
## the database open the same SQLite file themselves, after the app has closed its own connection.

import BDD from "std/bdd"
import HTTP from "std/http"
import Db from "pkg/db/db"
import DataDir from "../src/data_dir"
import Database from "../src/database"
import Migrations from "../src/migrations"

PORT = "port"
REPLY = "reply"
DB_DIR = "db_dir"
DB_URL = "db_url"
STARTED = "started"
SQL_ERROR = "sql_error"
MEMORY_URL = "sqlite::memory:"
LISTENING = "listening on "
SOCKET_MS = 5_000
FOLDER_PREFIX = "campfire-spec-"
STALE_SECONDS = 3_600
PRIVATE_FOLDER_MODE = 448

struct Reply
  status: Int
  headers: Map[String, String]
  body: String
end

def main() -> Void
  BDD.run([
    BDD.step("the app listens on a free port", &start_on_memory),
    BDD.step("a fresh database", &fresh_database),
    BDD.step("the database is migrated", &migrate_database),
    BDD.step("the app starts", &start_on_file),
    BDD.step("the app restarts", &restart_app),
    BDD.step("the start applied every migration", &applied_every_migration),
    BDD.step("the start applied no migration", &applied_no_migration),
    BDD.step("the health check reports the latest schema version", &health_has_latest_version),
    BDD.step("the database has the tables:", &has_tables),
    BDD.step("the database is removed", &remove_database),
    BDD.step("the data folder {string} is prepared", &prepare_data_dir),
    BDD.step("the data folder {string} is private", &data_dir_is_private),
    BDD.step("the recorded checksums are:", &checksums_are),
    BDD.step("I run the sql {string}", &run_sql),
    BDD.step("I try the sql {string}", &try_sql),
    BDD.step("the sql fails with {string}", &sql_fails_with),
    BDD.step("the query {string} gives {int}", &query_gives),
    BDD.step("I get {string}", &get),
    BDD.step("the status is {int}", &status_is),
    BDD.step("the header {string} is {string}", &header_is),
    BDD.step("the body is {string}", &body_is),
    BDD.step("the body contains {string}", &body_contains),
  ])
end

def start_on_memory(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return start_app(ctx, MEMORY_URL)
end

def start_on_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return start_app(ctx, text_of(ctx, DB_URL))
end

# The first input line is the database url. The program answers with the `database:` line, then `listening on
# http://127.0.0.1:PORT`.
def start_app(ctx: BDD.Context, url: String) -> BDD.Context
  started = BDD.when_line(BDD.given_program(ctx, "fixtures/server.agc"), url)
  return read_startup(started)
end

# Another app on the same database: the program stops its server and starts a new one.
def restart_app(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return read_startup(BDD.when_line(ctx, "restart"))
end

# Reads the lines up to `listening on`, and keeps the port and the `database:` line.
def read_startup(ctx: BDD.Context) -> BDD.Context
  database = ""
  for _ in 0..5
    line = BDD.read_line(ctx, SOCKET_MS)
    if not line.ok?
      # The check of stderr shows what the program wrote there (a failure to start says why), when it did write.
      return BDD.assert(BDD.then_stderr(ctx, ""), false, "the app did not start: #{line.message}")
    end

    text = line.unwrap!
    if text.start_with?(LISTENING)
      port = text.split(":").last.to_i!
      return BDD.set(BDD.set(ctx, PORT, JSON.from(port)), STARTED, JSON.from(database))
    end

    database = text
  end

  return BDD.assert(ctx, false, "the app did not say where it listens")
end

def get(ctx: BDD.Context, args: List[String]) -> BDD.Context
  port = JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!
  client = HTTP.client().unwrap!
  response = HTTP.get(client, "http://127.0.0.1:#{port}#{args[0]}")
  HTTP.close_client(client)
  if not response.ok?
    return BDD.assert(ctx, false, "GET #{args[0]} failed: #{response.message}")
  end

  return BDD.set(ctx, REPLY, JSON.from(reply_of(response.unwrap!)))
end

def reply_of(response: HttpResponse) -> Reply
  start: Map[String, String] = {}
  headers = response.headers.reduce(start) do |acc, header| acc.put(header.name.downcase, header.value) end
  body = String.from_bytes(response.body).unwrap_or("")
  return Reply(status: response.status, headers: headers, body: body)
end

def last_reply(ctx: BDD.Context) -> Reply
  return JSON.decode(BDD.get(ctx, REPLY).unwrap!, Reply).unwrap!
end

def status_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.status == args[0].to_i!, "the status is #{reply.status}")
end

def header_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.headers.get(args[0].downcase, "") == args[1], "the headers are #{reply.headers}")
end

def body_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.body == args[0], "the body is #{reply.body}")
end

def body_contains(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.body.include?(args[0]), "the body is #{reply.body}")
end

def text_of(ctx: BDD.Context, name: String) -> String
  return JSON.string(BDD.get(ctx, name).unwrap!).unwrap!
end

def fresh_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  root = System.env("TMPDIR").unwrap_or("/tmp")
  remove_stale_folders(root)
  dir = Path.join([root, "#{FOLDER_PREFIX}#{SecureRandom.hex(8)}"]).unwrap!
  made = Dir.mkdir_private(dir)
  if not made.ok?
    return BDD.assert(ctx, false, "cannot make #{dir}: #{made.message}")
  end

  url = "sqlite:#{dir}/campfire.db?fts5=required"
  return BDD.set(BDD.set(ctx, DB_DIR, JSON.from(dir)), DB_URL, JSON.from(url))
end

# A scenario that fails before its last step leaves its folder behind; the next run sweeps the ones that are old
# enough not to belong to a run in progress.
def remove_stale_folders(root: String) -> Void
  nothing: List[String] = []
  names = Dir.list(root).unwrap_or(nothing)
  now = Time.now_ms / 1_000
  for name in names
    path = Path.join([root, name]).unwrap!
    info = File.stat(path)
    if name.start_with?(FOLDER_PREFIX) and info.ok? and now - info.unwrap!.modified_seconds > STALE_SECONDS
      Path.remove(path)
    end
  end
end

def remove_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  removed = Path.remove(text_of(ctx, DB_DIR))
  return BDD.assert(ctx, removed.ok?, "cannot remove the database folder: #{removed.message}")
end

def migrate_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  migrated = Database.migrate(text_of(ctx, DB_URL))
  return BDD.assert(ctx, migrated.ok?, "the migrations failed: #{migrated.message}")
end

def prepare_data_dir(ctx: BDD.Context, args: List[String]) -> BDD.Context
  prepared = DataDir.ensure(Path.join([text_of(ctx, DB_DIR), args[0]]).unwrap!)
  return BDD.assert(ctx, prepared.ok?, "cannot prepare #{args[0]}: #{prepared.message}")
end

def data_dir_is_private(ctx: BDD.Context, args: List[String]) -> BDD.Context
  info = File.stat(Path.join([text_of(ctx, DB_DIR), args[0]]).unwrap!)
  if not info.ok?
    return BDD.assert(ctx, false, "cannot stat #{args[0]}: #{info.message}")
  end

  mode = info.unwrap!.mode
  return BDD.assert(ctx, mode == PRIVATE_FOLDER_MODE, "the mode of #{args[0]} is #{mode}, not #{PRIVATE_FOLDER_MODE}")
end

# The table rows are `version | checksum`. The checksum is what `Migrate` recorded, so a changed statement shows here.
def checksums_are(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = rows_of(ctx, "select version, checksum from schema_migrations order by version")
  recorded = rows.map do |row|
    "#{value_int(row.get("version", Db.Value.Null))} #{value_text(row.get("checksum", Db.Value.Null))}"
  end

  expected = BDD.table(ctx).map do |row| "#{row[0]} #{row[1]}" end
  return BDD.assert(ctx, recorded.join("\n") == expected.join("\n"), "the recorded checksums are #{recorded}")
end

def applied_every_migration(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return started_with(ctx, Migrations.all().length)
end

def applied_no_migration(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return started_with(ctx, 0)
end

def started_with(ctx: BDD.Context, applied: Int) -> BDD.Context
  expected = "database: schema version #{Migrations.latest()}, migrations applied: #{applied}"
  actual = text_of(ctx, STARTED)
  return BDD.assert(ctx, actual == expected, "the app said #{actual.inspect}, not #{expected.inspect}")
end

def health_has_latest_version(ctx: BDD.Context, args: List[String]) -> BDD.Context
  got = get(ctx, ["/health"])
  expected = "{\"schema_version\":#{Migrations.latest()},\"status\":\"ok\"}"
  return BDD.assert(got, last_reply(got).body == expected, "the body is #{last_reply(got).body}")
end

def has_tables(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = rows_of(ctx, "select name from sqlite_master where type = 'table'")
  names = rows.map do |row| value_text(row.get("name", Db.Value.Null)) end
  wanted = BDD.table(ctx).map do |row| row[0] end
  missing = wanted.select do |name| not names.any? do |known| known == name end end
  return BDD.assert(ctx, missing.empty?, "the tables are missing: #{missing}, there are #{names}")
end

def run_sql(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| Db.execute(conn, args[0], []) end
  return BDD.assert(ctx, outcome.ok?, "#{args[0]} failed: #{outcome.message}")
end

def try_sql(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| Db.execute(conn, args[0], []) end
  failure = ""
  if not outcome.ok?
    failure = outcome.message
  end

  return BDD.set(ctx, SQL_ERROR, JSON.from(failure))
end

def sql_fails_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  message = text_of(ctx, SQL_ERROR)
  return BDD.assert(ctx, message.include?(args[0]), "the sql said #{message.inspect}, not #{args[0].inspect}")
end

def query_gives(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = rows_of(ctx, args[0])
  count = value_int(rows[0].values[0])
  return BDD.assert(ctx, count == args[1].to_i!, "the query gave #{count}")
end

# A connection belongs to the task that opened it, so each step opens its own and closes it.
def with_database[R](ctx: BDD.Context, body: Fn[Db.Connection, Result[R]]) -> Result[R]
  conn = try Db.open(text_of(ctx, DB_URL))
  outcome = body.call(conn)
  Db.close(conn)
  return outcome
end

def rows_of(ctx: BDD.Context, sql: String) -> List[Db.Row]
  return with_database(ctx) do |conn| Db.query(conn, sql, []) end.unwrap!
end

def value_text(value: Db.Value) -> String
  case value
    Db.Value.Text(text) -> return text
    _ -> return ""
  end
end

def value_int(value: Db.Value) -> Int
  case value
    Db.Value.Int(number) -> return number
    _ -> return -1
  end
end

## The steps of the features. The program of `fixtures/server.agc` serves the app on 127.0.0.1 and a free port on the
## database that the steps name in its environment (its input only carries `restart`), and the steps talk to it with
## the HTTP client of `std/http`. The steps of the database open the same SQLite file themselves, after the app has
## closed its own connection.

import BDD from "std/bdd"
import Db from "pkg/db/db"
import HttpSteps from "http_steps"
import MailSteps from "mail_steps"
import SmtpSteps from "smtp_steps"
import DataDir from "../src/data_dir"
import Database from "../src/database"
import Migrations from "../src/migrations"

DB_DIR = "db_dir"
DB_URL = "db_url"
STARTED = "started"
STARTUP = "startup_lines"
SQL_ERROR = "sql_error"
LISTENING = "listening on "
SOCKET_MS = 5_000
FOLDER_PREFIX = "campfire-spec-"
PRIVATE_FOLDER_MODE = 448

def main() -> Void
  own = [
    BDD.step("a fresh database", &fresh_database),
    BDD.step("the database is migrated", &migrate_database),
    BDD.step("the app starts", &start_on_file),
    BDD.step("the app starts with secure cookies", &start_with_secure_cookies),
    BDD.step("the app restarts", &restart_app),
    BDD.step("the start applied every migration", &applied_every_migration),
    BDD.step("the start applied no migration", &applied_no_migration),
    BDD.step("the health check reports the latest schema version", &health_has_latest_version),
    BDD.step("the app said {string}", &app_said),
    BDD.step("the app said a line starting with {string}", &app_said_prefix),
    BDD.step("the database does not hold the token of the link", &token_is_not_stored),
    BDD.step("the database has the tables:", &has_tables),
    BDD.step("the data folder {string} is prepared", &prepare_data_dir),
    BDD.step("the data folder {string} is private", &data_dir_is_private),
    BDD.step("the recorded checksums are:", &checksums_are),
    BDD.step("I run the sql {string}", &run_sql),
    BDD.step("I try the sql {string}", &try_sql),
    BDD.step("the sql fails with {string}", &sql_fails_with),
    BDD.step("the query {string} gives {int}", &query_gives),
    BDD.step("the query {string} gives at most {int}", &query_gives_at_most),
  ]

  BDD.run(own.concat(HttpSteps.steps()).concat(SmtpSteps.steps()).concat(MailSteps.steps()))
end

def start_on_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return start_app(ctx, text_of(ctx, DB_URL), "false")
end

def start_with_secure_cookies(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return start_app(ctx, text_of(ctx, DB_URL), "true")
end

# The program reads its address and its database from the environment, as `campfire.agc` does, and answers with the
# `database:` line, then `listening on http://127.0.0.1:PORT`. Every variable it reads is set here, so the specs do not
# depend on the environment of whoever runs them. Each start draws its own session secret.
def start_app(ctx: BDD.Context, url: String, secure_cookies: String) -> BDD.Context
  settings = {
    "CAMPFIRE_HOST": "127.0.0.1",
    "CAMPFIRE_PORT": "0",
    "CAMPFIRE_DATA_DIR": "unused",
    "CAMPFIRE_DATABASE_URL": url,
    "CAMPFIRE_SESSION_SECRET": SecureRandom.hex(32),
    "CAMPFIRE_SECURE_COOKIES": secure_cookies,
  }

  mail = MailSteps.app_environment(ctx)
  all = mail.keys.reduce(settings) do |acc, name| acc.put(name, mail.get(name, "")) end
  configured = all.keys.reduce(ctx) do |acc, name| BDD.given_env(acc, name, all.get(name, "")) end

  return read_startup(BDD.given_program(configured, "fixtures/server.agc"))
end

# Another app on the same database: the program stops its server and starts a new one.
def restart_app(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return read_startup(BDD.when_line(ctx, "restart"))
end

# Reads the lines up to `listening on`, and keeps the port and the `database:` line.
def read_startup(ctx: BDD.Context) -> BDD.Context
  database = ""
  said: List[String] = []
  for _ in 0..5
    line = BDD.read_line(ctx, SOCKET_MS)
    if not line.ok?
      # The check of stderr shows what the program wrote there (a failure to start says why), when it did write.
      return BDD.assert(BDD.then_stderr(ctx, ""), false, "the app did not start: #{line.message}")
    end

    text = line.unwrap!
    if text.start_with?(LISTENING)
      port = text.split(":").last.to_i!
      kept = BDD.set(BDD.set(ctx, HttpSteps.PORT, JSON.from(port)), STARTED, JSON.from(database))
      return BDD.set(kept, STARTUP, JSON.from(said.join("\n")))
    end

    database = text
    said = said.push(text)
  end

  return BDD.assert(ctx, false, "the app did not say where it listens")
end

def text_of(ctx: BDD.Context, name: String) -> String
  return JSON.string(BDD.get(ctx, name).unwrap!).unwrap!
end

# The folder goes away when the scenario ends, passed or failed, so no step has to remove it.
def fresh_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  root = System.env("TMPDIR").unwrap_or("/tmp")
  dir = Path.join([root, "#{FOLDER_PREFIX}#{SecureRandom.hex(8)}"]).unwrap!
  made = Dir.mkdir_private(dir)
  if not made.ok?
    return BDD.assert(ctx, false, "cannot make #{dir}: #{made.message}")
  end

  url = "sqlite:#{dir}/campfire.db?fts5=required"
  stored = BDD.set(BDD.set(ctx, DB_DIR, JSON.from(dir)), DB_URL, JSON.from(url))
  # The hook's result is the removal's: a folder that cannot be removed fails the scenario.
  return BDD.after(stored) do |_| Path.remove(dir) end
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
  return BDD.assert(ctx, recorded == expected, "the recorded checksums are #{recorded}")
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

def app_said(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = text_of(ctx, STARTUP).split("\n")
  return BDD.assert(ctx, lines.include?(args[0]), "the app said:\n#{lines.join("\n")}")
end

def app_said_prefix(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = text_of(ctx, STARTUP).split("\n")
  found = lines.any? do |line| line.start_with?(args[0]) end
  return BDD.assert(ctx, found, "the app said:\n#{lines.join("\n")}")
end

# Only a hash of the token is kept: neither the token nor a part of it is in a row of the table.
def token_is_not_stored(ctx: BDD.Context, args: List[String]) -> BDD.Context
  token = MailSteps.link_token(ctx)
  rows = rows_of(ctx, "select token_digest from password_resets")
  stored = rows.map do |row| value_text(row.get("token_digest", Db.Value.Null)) end
  leaked = stored.any? do |digest| digest.include?(token) or token.include?(digest) end
  return BDD.assert(ctx, not token.empty? and not leaked, "the table holds #{stored}, the token is #{token}")
end

def health_has_latest_version(ctx: BDD.Context, args: List[String]) -> BDD.Context
  got = HttpSteps.get(ctx, ["/health"])
  expected = "{\"schema_version\":#{Migrations.latest()},\"status\":\"ok\"}"
  return BDD.assert(got, HttpSteps.last_body(got) == expected, "the body is #{HttpSteps.last_body(got)}")
end

def has_tables(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = rows_of(ctx, "select name from sqlite_master where type = 'table'")
  names = rows.map do |row| value_text(row.get("name", Db.Value.Null)) end
  wanted = BDD.table(ctx).map do |row| row[0] end
  missing = wanted.select do |name| not names.include?(name) end
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

def query_gives_at_most(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = rows_of(ctx, args[0])
  count = value_int(rows[0].values[0])
  return BDD.assert(ctx, count <= args[1].to_i!, "the query gave #{count}")
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

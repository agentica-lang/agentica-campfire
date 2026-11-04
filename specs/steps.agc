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
import Passwords from "../src/passwords"
import Rooms from "../src/rooms"

DB_DIR = "db_dir"
DB_URL = "db_url"
STARTED = "started"
STARTUP = "startup_lines"
UPDATED = "updated"
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
    BDD.step("a member {string} with the email {string} exists", &member_exists),
    BDD.step("a closed room {string} with the members {string}", &closed_room_exists),
    BDD.step("a direct room with the members {string}", &direct_room_exists),
    BDD.step("the room {int} has {int} messages", &room_has_messages),
    BDD.step("{string} asks Rooms.update_closed to rename the room {int} and swap its members", &ask_update_closed),
    BDD.step("the update is refused", &update_is_refused),
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

# A person that the app did not make through a page (there is no invitation yet): the password is the same for every
# member, so `I sign in as` can sign them in, and they join the open rooms that exist, as an invitation will make them.
def member_exists(ctx: BDD.Context, args: List[String]) -> BDD.Context
  digest = Passwords.hash(HttpSteps.MEMBER_PASSWORD)
  if not digest.ok?
    return BDD.assert(ctx, false, "cannot hash the password: #{digest.message}")
  end

  made = with_database(ctx) do |conn| add_member(conn, args[0], args[1], digest.unwrap!) end
  return BDD.assert(ctx, made.ok?, "cannot make the member #{args[1]}: #{made.message}")
end

def add_member(conn: Db.Connection, name: String, email: String, digest: String) -> Result[Void]
  rows = try Db.query(
    conn,
    "insert into users (name, email, password_digest) values (?, ?, ?) returning id",
    [Db.Value.Text(name), Db.Value.Text(email), Db.Value.Text(digest)],
  )

  return Rooms.grant_open_rooms(conn, value_int(rows[0].get("id", Db.Value.Null)))
end

# The first person on the list makes the room. `members` are emails separated by commas.
def closed_room_exists(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return make_room(ctx, Db.Value.Text(args[0]), "closed", args[1])
end

def direct_room_exists(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return make_room(ctx, Db.Value.Null, "direct", args[0])
end

def make_room(ctx: BDD.Context, name: Db.Value, kind: String, members: String) -> BDD.Context
  emails = members.split(",").map do |email| email.strip end
  made = with_database(ctx) do |conn| insert_room(conn, name, kind, emails) end
  return BDD.assert(ctx, made.ok?, "cannot make the #{kind} room: #{made.message}")
end

def insert_room(conn: Db.Connection, name: Db.Value, kind: String, emails: List[String]) -> Result[Void]
  rooms = try Db.query(
    conn,
    "insert into rooms (name, kind, creator_id) values (?, ?, (select id from users where email = ?)) returning id",
    [name, Db.Value.Text(kind), Db.Value.Text(emails[0])],
  )

  room_id = value_int(rooms[0].get("id", Db.Value.Null))
  for email in emails
    try Db.execute(
      conn,
      "insert into memberships (room_id, user_id) select ?, id from users where email = ?",
      [Db.Value.Int(room_id), Db.Value.Text(email)],
    )
  end

  return ok()
end

# Messages `message 001`, `message 002`... by the person who made the room. The zero padding keeps one text from being
# a part of another (`message 04` is in `message 045`, `message 004` is not).
def room_has_messages(ctx: BDD.Context, args: List[String]) -> BDD.Context
  seeded = with_database(ctx) do |conn| add_messages(conn, args[0].to_i!, args[1].to_i!) end
  return BDD.assert(ctx, seeded.ok?, "cannot add the messages: #{seeded.message}")
end

def add_messages(conn: Db.Connection, room_id: Int, count: Int) -> Result[Int]
  return Db.execute(
    conn,
    "with recursive n(i) as (select 1 union all select i + 1 from n where i < ?) " +
    "insert into messages (room_id, creator_id, body, client_message_id) " +
    "select ?, (select creator_id from rooms where id = ?), printf('message %03d', i), 'seed-' || i from n",
    [Db.Value.Int(count), Db.Value.Int(room_id), Db.Value.Int(room_id)],
  )
end

# `Rooms.update_closed` straight, as the person with that email: it renames the room, takes out the first two people
# and puts in the third. The pages check who may edit before they call it, so only a call that skips them reaches the
# check inside the transaction.
def ask_update_closed(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| update_as(conn, args[0], args[1].to_i!) end
  if not outcome.ok?
    return BDD.assert(ctx, false, "Rooms.update_closed failed: #{outcome.message}")
  end

  return BDD.set(ctx, UPDATED, JSON.from("#{outcome.unwrap!}"))
end

def update_as(conn: Db.Connection, email: String, room_id: Int) -> Result[Bool]
  rows = try Db.query(conn, "select id from users where email = ?", [Db.Value.Text(email)])
  editor_id = value_int(rows[0].get("id", Db.Value.Null))
  return Rooms.update_closed(conn, room_id, editor_id, "Renamed", [3], [1, 2])
end

def update_is_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, text_of(ctx, UPDATED) == "false", "the update said #{text_of(ctx, UPDATED)}")
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

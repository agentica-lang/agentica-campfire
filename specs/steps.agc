## The steps of the features. The program of `fixtures/server.agc` serves the app on 127.0.0.1 and a free port on the
## database that the steps name in its environment (its input only carries `restart`), and the steps talk to it with
## the HTTP client of `std/http`. The steps of the database open the same SQLite file themselves, after the app has
## closed its own connection.

import BDD from "std/bdd"
import Db from "pkg/db/db"
import Migrate from "pkg/db/migrate"
import CableSteps from "cable_steps"
import HttpSteps from "http_steps"
import MailSteps from "mail_steps"
import SmtpSteps from "smtp_steps"
import DataDir from "../src/campfire/data_dir"
import Accounts from "../src/campfire/accounts"
import Auth from "../src/campfire/auth"
import Avatars from "../src/campfire/avatars"
import Bans from "../src/campfire/bans"
import Bcrypt from "../src/campfire/bcrypt"
import Bots from "../src/campfire/bots"
import Database from "../src/campfire/repo/database"
import HtmlSanitizer from "../src/campfire/html_sanitizer"
import Migrations from "../src/campfire/repo/migrations"
import Rails from "../src/campfire/repo/rails"
import Rooms from "../src/campfire/rooms"

DB_DIR = "db_dir"
DB_URL = "db_url"
RAILS_URL = "rails_url"
RAILS_FIXTURE = "specs/fixtures/rails/campfire.sqlite3"
# What `fixtures/rails/make_avatar.sh` made: the rows of Active Storage for the avatar of user 1, and the files of the
# Disk service that they name.
AVATAR_SQL = "specs/fixtures/rails/avatar.sql"
AVATAR_STORAGE = "specs/fixtures/rails/storage"
# The secret of the Rails app that made the tokens of `test/signed_id_test.agc`.
SECRET_KEY_BASE = (
  "5d1f1c3e0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f"
)
# The scrypt digest of `HttpSteps.MEMBER_PASSWORD` at a cost of 1024 (the app's own is 65536, 64 MiB for each hash and
# each sign-in, which was about 75 % of the CPU of the suite). It is in the form that `Passwords.hash` writes, which
# carries its cost, so `Passwords.verify` checks it with the cost it names. Made with Python:
# `hashlib.scrypt(b"another long password", salt=bytes(range(1, 17)), n=1024, r=8, p=2, dklen=32)`.
MEMBER_DIGEST = "scrypt$1024$8$2$AQIDBAUGBwgJCgsMDQ4PEA==$k6UaLA1ch6VFTNpUo+rxtZz9UjXZ5kX/WzWpBpW+qS4="
STARTED = "started"
STARTUP = "startup_lines"
UPDATED = "updated"
CHANGED = "changed"
JOINED = "joined"
SESSION = "session"
SQL_ERROR = "sql_error"
BCRYPT_LIBRARY = "bcrypt_library"
LISTENING = "listening on "
# How long a start may take before its `listening on` line: the first start after a source change compiles the whole
# app (about 6 s on a CI runner). The wait ends at the line, so a warm start does not wait; only an app that never
# listens costs the full time. The steps that expect a failing start to exit use the same bound.
START_MS = 30_000
FOLDER_PREFIX = "campfire-spec-"
# Where the migrated database that "a fresh database" copies is kept: `_build/spec-template/` of the project (`_build/`
# is its build folder, which git ignores). The file name is a digest (see `schema_template`). A template or a scratch
# file is removed only when it is older than this many seconds.
BUILD_DIR = "_build"
TEMPLATE_FOLDER = "spec-template"
TEMPLATE_KEEP_SECONDS = 600
PACKAGE_LOCK = "agentica.lock"
PRIVATE_FOLDER_MODE = 448
FILE_MS = 5_000
COPY_CHUNK = 65_536

def main() -> Void
  own = [
    BDD.step("a fresh database", &fresh_database),
    BDD.step("an empty database", &empty_database),
    BDD.step("the database is migrated", &migrate_database),
    BDD.step("the app starts", &start_on_file),
    BDD.step("the app starts with secure cookies", &start_with_secure_cookies),
    BDD.step("the app is started and stops", &start_that_fails),
    BDD.step("the bcrypt library is {string}", &choose_bcrypt_library),
    BDD.step("bcrypt digests can be checked on this system", &bcrypt_can_be_checked),
    BDD.step("this system is Linux", &system_is_linux),
    BDD.step("the app starts with {int} database connections that wait {int} milliseconds", &start_with_pool),
    BDD.step("the app restarts", &restart_app),
    BDD.step("the app restarts with the message cache off", &restart_app_without_cache),
    BDD.step("the app restarts with the page cache off", &restart_app_without_page_cache),
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
    BDD.step("a database made by Rails", &rails_database),
    BDD.step("a copy of the database made by Rails is next to it", &rails_copy),
    BDD.step("{string} are as Rails made them", &tables_as_rails),
    BDD.step("the tables are those of Rails and {string}", &tables_of_rails_and),
    BDD.step("the database does not have the table {string}", &lacks_table),
    BDD.step("a member {string} with the email {string} exists", &member_exists),
    BDD.step(
      "a user {string} with the email {string}, the role {string} and the status {string} exists",
      &user_exists,
    ),
    BDD.step("a bot {string} with the token {string} exists", &bot_exists),
    BDD.step("a member {string} with the email {string} and the password digest {string} exists", &member_with_digest),
    BDD.step("a closed room {string} with the members {string}", &closed_room_exists),
    BDD.step("a direct room with the members {string}", &direct_room_exists),
    BDD.step("the avatar that Rails stored for the user 1", &stored_avatar),
    BDD.step("the stored file {string} is {string}", &stored_file_is),
    BDD.step("the body is the stored variant of the avatar of the user {int}", &body_is_variant),
    BDD.step("the body is the stored original of the avatar of the user {int}", &body_is_original),
    BDD.step("the room {int} has {int} messages", &room_has_messages),
    BDD.step("a message {string} in the room {int} at {string}", &message_at),
    BDD.step("an orphan message {string} in the room {int}", &orphan_message),
    BDD.step("{string} asks Rooms.update_room to rename the room {int} and swap its members", &ask_update_room),
    BDD.step("the update is refused", &update_is_refused),
    BDD.step("{string} asks Rooms.post to post {string} in the room {int}", &ask_post),
    BDD.step("{string} asks Accounts to {string} the user {int}", &ask_accounts),
    BDD.step("{string} asks Bots to {string} the bot {int}", &ask_bots),
    BDD.step("{string} asks Auth.join_hashed to sign up with the code {string}", &ask_join_hashed),
    BDD.step("the join is {string}", &join_is),
    BDD.step("Auth.open_session is asked for the user {int}", &ask_open_session),
    BDD.step("the session is refused", &session_is_refused),
    BDD.step("the session is opened", &session_is_opened),
    BDD.step("the change is refused", &change_is_refused),
    BDD.step("I run the sql {string}", &run_sql),
    BDD.step("the messages of the user {int} are taken away as the removal task takes them", &run_removal),
    BDD.step("I try the sql {string}", &try_sql),
    BDD.step("the sql fails with {string}", &sql_fails_with),
    BDD.step("the query {string} gives {int}", &query_gives),
    BDD.step("the query {string} gives at most {int}", &query_gives_at_most),
    BDD.step("the query {string} gives {int} within {int} milliseconds", &query_gives_within),
    BDD.step("{string} asks Rooms to delete the room {int} while a message is posted in between", &ask_delete_between),
    BDD.step("{string} takes the room {int} away and deletes {int} of its messages", &ask_delete_some),
  ]

  BDD.run(own.concat(HttpSteps.steps()).concat(SmtpSteps.steps()).concat(MailSteps.steps()).concat(CableSteps.steps()))
end

def start_on_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return start_app(ctx, text_of(ctx, DB_URL), "false", {})
end

def start_with_secure_cookies(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return start_app(ctx, text_of(ctx, DB_URL), "true", {})
end

# A small pool that gives up quickly, so a burst of requests finds every connection busy.
def start_with_pool(ctx: BDD.Context, args: List[String]) -> BDD.Context
  pool = {"CAMPFIRE_DB_POOL_SIZE": args[0], "CAMPFIRE_DB_CHECKOUT_MS": args[1]}
  return start_app(ctx, text_of(ctx, DB_URL), "false", pool)
end

# The program reads its address and its database from the environment, as `campfire.agc` does, and answers with the
# `database:` line, then `listening on http://127.0.0.1:PORT`. Every variable it reads is set here, so the specs do not
# depend on the environment of whoever runs them. Each start draws its own session secret.
def start_app(ctx: BDD.Context, url: String, secure_cookies: String, pool: Map[String, String]) -> BDD.Context
  return read_startup(configured_program(ctx, url, secure_cookies, pool))
end

# The program of `fixtures/server.agc` with the environment of `start_app`, not yet started.
def configured_program(ctx: BDD.Context, url: String, secure_cookies: String, pool: Map[String, String]) -> BDD.Context
  settings = {
    "CAMPFIRE_HOST": "127.0.0.1",
    "CAMPFIRE_PORT": "0",
    "CAMPFIRE_DATA_DIR": "unused",
    "CAMPFIRE_DATABASE_URL": url,
    "CAMPFIRE_SESSION_SECRET": SecureRandom.hex(32),
    "CAMPFIRE_SECURE_COOKIES": secure_cookies,
    "CAMPFIRE_DB_POOL_SIZE": pool.get("CAMPFIRE_DB_POOL_SIZE", ""),
    "CAMPFIRE_DB_CHECKOUT_MS": pool.get("CAMPFIRE_DB_CHECKOUT_MS", ""),
    "CAMPFIRE_BCRYPT_LIBRARY": bcrypt_library(ctx),
    "SECRET_KEY_BASE": SECRET_KEY_BASE,
    "CAMPFIRE_STORAGE_DIR": storage_dir(ctx),
    "CAMPFIRE_ASSETS_DIR": assets_dir(),
  }

  mail = MailSteps.app_environment(ctx)
  all = mail.keys.reduce(settings) do |acc, name| acc.put(name, mail.get(name, "")) end
  configured = all.keys.reduce(ctx) do |acc, name| BDD.given_env(acc, name, all.get(name, "")) end

  return BDD.given_program(configured, "fixtures/server.agc")
end

# A start that must stop: the program exits with code 1 and its stderr says why (the step after it compares the text).
def start_that_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  program = configured_program(ctx, text_of(ctx, DB_URL), "false", {})
  return BDD.then_exit(program, 1, START_MS)
end

# What a scenario says with `the bcrypt library is`, else the library of whoever runs the specs (a macOS or Windows
# runner names its libxcrypt build in `CAMPFIRE_BCRYPT_LIBRARY`), else "" for the default of the system.
def bcrypt_library(ctx: BDD.Context) -> String
  if BDD.get(ctx, BCRYPT_LIBRARY).ok?
    return text_of(ctx, BCRYPT_LIBRARY)
  end

  return System.env("CAMPFIRE_BCRYPT_LIBRARY").unwrap_or("")
end

def choose_bcrypt_library(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, BCRYPT_LIBRARY, JSON.from(args[0]))
end

# The scenarios that sign in with a bcrypt digest need the library: where it is missing (macOS and Windows without
# `CAMPFIRE_BCRYPT_LIBRARY`) they are skipped. Linux has it, so there a failure fails the scenario.
def bcrypt_can_be_checked(ctx: BDD.Context, args: List[String]) -> BDD.Context
  library = bcrypt_library(ctx)
  probe = Bcrypt.verify("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW", library)
  if probe.ok?
    return ctx
  end

  if System.os() == "linux" and library.empty?
    return BDD.assert(ctx, false, "libcrypt.so.1 cannot check bcrypt: #{probe.message}")
  end

  return BDD.skip(ctx, "no library for bcrypt digests: #{probe.message}")
end

def system_is_linux(ctx: BDD.Context, args: List[String]) -> BDD.Context
  if System.os() == "linux"
    return ctx
  end

  return BDD.skip(ctx, "this scenario names libcrypt.so.1, which only Linux has")
end

# Another app on the same database: the program stops its server and starts a new one.
def restart_app(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return read_startup(BDD.when_line(ctx, "restart"))
end

# The same database again, with no cache of rendered messages: what the pages show must not depend on it.
def restart_app_without_cache(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return read_startup(BDD.when_line(ctx, "restart without cache"))
end

# The same database again, with no cache of whole pages: the pages must be the same but for the id of the form.
def restart_app_without_page_cache(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return read_startup(BDD.when_line(ctx, "restart without page cache"))
end

# Reads the lines up to `listening on`, and keeps the port and the `database:` line.
def read_startup(ctx: BDD.Context) -> BDD.Context
  database = ""
  said: List[String] = []
  for _ in 0..5
    line = BDD.read_line(ctx, START_MS)
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

# A folder with a database that has every migration of the app, as a first start leaves it: a copy of the template. The
# folder goes away when the scenario ends, passed or failed, so no step has to remove it.
def fresh_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return new_database(ctx, true)
end

# A folder with no database file: the one for the scenarios that look at the migrations themselves.
def empty_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return new_database(ctx, false)
end

def new_database(ctx: BDD.Context, migrated: Bool) -> BDD.Context
  root = System.env("TMPDIR").unwrap_or("/tmp")
  dir = Path.join([root, "#{FOLDER_PREFIX}#{SecureRandom.hex(8)}"]).unwrap!
  made = Dir.mkdir_private(dir)
  if not made.ok?
    return BDD.assert(ctx, false, "cannot make #{dir}: #{made.message}")
  end

  url = "sqlite:#{dir}/campfire.db?fts5=required"
  stored = BDD.set(BDD.set(ctx, DB_DIR, JSON.from(dir)), DB_URL, JSON.from(url))
  # The hook's result is the removal's: a folder that cannot be removed fails the scenario.
  hooked = BDD.after(stored) do |_| Path.remove(dir) end
  if not migrated
    return hooked
  end

  copied = copy_template("#{dir}/campfire.db")
  return BDD.assert(hooked, copied.ok?, "cannot copy the migrated database: #{copied.message}")
end

def copy_template(to: String) -> Result[Void]
  template = try schema_template()
  return copy_path(template, to)
end

# The migrated database that "a fresh database" copies, made by the first scenario that needs it and kept for the
# next ones, in this run and in the runs that follow while nothing it depends on changes. The file name is the digest
# of the migrations (versions, names and statements) and of `agentica.lock` (the pin of the package that migrates), so
# a changed migration or package makes another file. The files run in parallel: each one that finds no template
# migrates a database of its own and moves it into place, which is atomic and gives the same bytes whoever wins (the
# others find the file there and drop theirs).
def schema_template() -> Result[String]
  folder = try template_dir()
  path = try Path.join([folder, "#{try schema_digest()}.db"])
  if File.stat(path).ok?
    return ok(path)
  end

  scratch = try Path.join([folder, "making-#{SecureRandom.hex(8)}.db"])
  migrated = Database.migrate("sqlite:#{scratch}?fts5=required")
  if not migrated.ok?
    _ = Path.remove(scratch)
    return error(migrated.message)
  end

  # A rename onto a file that exists fails: another file of specs won the race, and its template has the same bytes.
  moved = Path.rename(scratch, path)
  if not moved.ok?
    _ = Path.remove(scratch)
    if not File.stat(path).ok?
      return error(moved.message)
    end

    return ok(path)
  end

  remove_old_templates(folder, path)
  return ok(path)
end

# The folder of the templates, in the project (the specs run from its root, as the fixtures above assume).
def template_dir() -> Result[String]
  build = try Path.join([try Path.cwd(), BUILD_DIR])
  _ = Dir.mkdir(build)
  folder = try Path.join([build, TEMPLATE_FOLDER])
  try Dir.mkdir(folder)
  return ok(folder)
end

# Templates of earlier digests and the scratch files of a run that stopped half way are of no use. Only the ones that
# nobody has touched for a few minutes go: a run of another checkout state may be using, or be making, a younger one.
def remove_old_templates(folder: String, keep: String) -> Void
  nothing: List[String] = []
  names = Dir.list(folder).unwrap_or(nothing)
  now = Time.now_ms() / 1000
  for name in names
    old = Path.join([folder, name]).unwrap!
    info = File.stat(old)
    if old != keep and info.ok? and now - info.unwrap!.modified_seconds > TEMPLATE_KEEP_SECONDS
      _ = Path.remove(old)
    end
  end
end

def schema_digest() -> Result[String]
  parts: List[String] = []
  for migration in Migrations.all()
    parts = parts.push("#{migration.version} #{migration.name}\n#{try statements_of(migration)}")
  end

  lock = try File.read_text(PACKAGE_LOCK)
  return ok(Digest.sha256_hexdigest("#{parts.join("\n")}\n#{lock}".bytes))
end

# The statements of a migration. A migration that is a function has none to show, so the digest would not see a change
# in it: it is an error here, and a spec that needs one must say how it enters the digest.
def statements_of(migration: Migrate.Migration) -> Result[String]
  case migration.action
    Migrate.Action.Statements(statements) -> return ok(statements.join(";\n"))
    Migrate.Action.Code(_) ->
      return error("migration #{migration.version} is a function: the template digest cannot see it")
  end
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
  rows = rows_of(ctx, "select version, checksum from #{Migrations.HISTORY_TABLE} order by version")
  recorded = rows.map do |row|
    "#{value_int(row.get("version", Db.Value.Null))} #{value_text(row.get("checksum", Db.Value.Null))}"
  end

  expected = BDD.table(ctx).map do |row| "#{row[0]} #{row[1]}" end
  return BDD.assert(ctx, recorded == expected, "the recorded checksums are #{recorded}")
end

# A person that the app did not make through a page (there is no invitation yet): the password is the same for every
# member, so `I sign in as` can sign them in, and they join the open rooms that exist, as an invitation will make them.
def member_exists(ctx: BDD.Context, args: List[String]) -> BDD.Context
  made = with_database(ctx) do |conn| add_member(conn, args[0], args[1], MEMBER_DIGEST) end
  return BDD.assert(ctx, made.ok?, "cannot make the member #{args[1]}: #{made.message}")
end

# A person that came with a digest that the app did not make (a bcrypt one of a Rails Campfire).
def member_with_digest(ctx: BDD.Context, args: List[String]) -> BDD.Context
  made = with_database(ctx) do |conn| add_member(conn, args[0], args[1], args[2]) end
  return BDD.assert(ctx, made.ok?, "cannot make the member #{args[1]}: #{made.message}")
end

def add_member(conn: Db.Connection, name: String, email: String, digest: String) -> Result[Void]
  rows = try Db.query(
    conn,
    "insert into users (name, email_address, password_digest, created_at, updated_at) " +
    "values (?, ?, ?, #{Rails.NOW}, #{Rails.NOW}) returning id",
    [Db.Value.Text(name), Db.Value.Text(email), Db.Value.Text(digest)],
  )

  return Rooms.grant_open_rooms(conn, value_int(rows[0].get("id", Db.Value.Null)))
end

# A person with the role and the status that a scenario names, who joins no room and has a digest nobody can match.
def user_exists(ctx: BDD.Context, args: List[String]) -> BDD.Context
  role = role_number(args[2])
  status = status_number(args[3])
  made = with_database(ctx) do |conn|
    Db.execute(
      conn,
      "insert into users (name, email_address, password_digest, role, status, created_at, updated_at) " +
      "values (?, ?, 'x', ?, ?, #{Rails.NOW}, #{Rails.NOW})",
      [Db.Value.Text(args[0]), Db.Value.Text(args[1]), Db.Value.Int(role), Db.Value.Int(status)],
    )
  end

  return BDD.assert(ctx, made.ok?, "cannot make the user #{args[1]}: #{made.message}")
end

def bot_exists(ctx: BDD.Context, args: List[String]) -> BDD.Context
  made = with_database(ctx) do |conn|
    Db.execute(
      conn,
      "insert into users (name, role, bot_token, created_at, updated_at) " +
      "values (?, #{Rails.BOT}, ?, #{Rails.NOW}, #{Rails.NOW})",
      [Db.Value.Text(args[0]), Db.Value.Text(args[1])],
    )
  end

  return BDD.assert(ctx, made.ok?, "cannot make the bot #{args[0]}: #{made.message}")
end

def role_number(name: String) -> Int
  if name == "administrator"
    return Rails.ADMINISTRATOR
  end

  if name == "bot"
    return Rails.BOT
  end

  return Rails.MEMBER
end

def status_number(name: String) -> Int
  if name == "deactivated"
    return Rails.DEACTIVATED
  end

  if name == "banned"
    return Rails.BANNED
  end

  return Rails.ACTIVE
end

# The first person on the list makes the room. `members` are emails separated by commas.
def closed_room_exists(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return make_room(ctx, Db.Value.Text(args[0]), Rooms.CLOSED, args[1])
end

def direct_room_exists(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return make_room(ctx, Db.Value.Null, Rooms.DIRECT, args[0])
end

def make_room(ctx: BDD.Context, name: Db.Value, room_type: String, members: String) -> BDD.Context
  emails = members.split(",").map do |email| email.strip end
  made = with_database(ctx) do |conn| insert_room(conn, name, room_type, emails) end
  return BDD.assert(ctx, made.ok?, "cannot make the #{room_type} room: #{made.message}")
end

def insert_room(conn: Db.Connection, name: Db.Value, room_type: String, emails: List[String]) -> Result[Void]
  rooms = try Db.query(
    conn,
    "insert into rooms (name, type, creator_id, created_at, updated_at) " +
    "values (?, ?, (select id from users where email_address = ?), #{Rails.NOW}, #{Rails.NOW}) returning id",
    [name, Db.Value.Text(room_type), Db.Value.Text(emails[0])],
  )

  room_id = value_int(rooms[0].get("id", Db.Value.Null))
  for email in emails
    try Db.execute(
      conn,
      "insert into memberships (room_id, user_id, created_at, updated_at) " +
      "select ?, id, #{Rails.NOW}, #{Rails.NOW} from users where email_address = ?",
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

# A message as Rails writes it (the row, its body and its search row) at a time that the scenario names, which
# `Rooms.post` cannot do: it stamps the time of the call. The author is the person who made the room.
def message_at(ctx: BDD.Context, args: List[String]) -> BDD.Context
  stored = with_database(ctx) do |conn| insert_message(conn, args[1].to_i!, args[0], args[2], false) end
  return BDD.assert(ctx, stored.ok?, "cannot add the message: #{stored.message}")
end

# A message whose author has no row, which a database that Rails seeded can have: the keys are off on this connection
# only, for the one insert.
def orphan_message(ctx: BDD.Context, args: List[String]) -> BDD.Context
  stored = with_database(ctx) do |conn|
    insert_message(conn, args[1].to_i!, args[0], "2026-03-01 09:00:00.000000", true)
  end

  return BDD.assert(ctx, stored.ok?, "cannot add the message: #{stored.message}")
end

def insert_message(conn: Db.Connection, room_id: Int, html: String, at: String, orphan: Bool) -> Result[Void]
  if orphan
    try Db.execute(conn, "pragma foreign_keys = off", [])
  end

  rows = try Db.query(
    conn,
    "insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) " +
    "select id, case when ? then 999 else creator_id end, 'step', ?, ? from rooms where id = ? returning id",
    [Db.Value.Int(orphan_flag(orphan)), Db.Value.Text(at), Db.Value.Text(at), Db.Value.Int(room_id)],
  )

  id = Db.Value.Int(value_int(rows[0].get("id", Db.Value.Null)))
  try Db.execute(
    conn,
    "insert into action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at) " +
    "values ('Message', ?, 'body', ?, ?, ?)",
    [id, Db.Value.Text(html), Db.Value.Text(at), Db.Value.Text(at)],
  )

  text = HtmlSanitizer.plain_text_of_clean(HtmlSanitizer.sanitize(html))
  try Db.execute(conn, "insert into message_search_index (rowid, body) values (?, ?)", [id, Db.Value.Text(text)])
  return ok()
end

def orphan_flag(orphan: Bool) -> Int
  if orphan
    return 1
  end

  return 0
end

# Each one goes through `Rooms.post`, so the seeded room is what the app itself makes: a body, a search row and a time.
def add_messages(conn: Db.Connection, room_id: Int, count: Int) -> Result[Void]
  rooms = try Db.query(conn, "select creator_id from rooms where id = ?", [Db.Value.Int(room_id)])
  creator_id = value_int(rooms[0].get("creator_id", Db.Value.Null))
  for i in (1..count).to_a
    try Rooms.post(conn, room_id, creator_id, "seed-#{i}", "message #{pad(i)}")
  end

  return ok()
end

def pad(number: Int) -> String
  text = "#{number}"
  return List.repeat("0", 3 - text.length).join("") + text
end

# `Rooms.update_room` straight, as the person with that email: it renames the room, takes out the first two people
# and puts in the third. The pages check who may edit before they call it, so only a call that skips them reaches the
# check inside the transaction.
def ask_update_room(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| update_as(conn, args[0], args[1].to_i!) end
  if not outcome.ok?
    return BDD.assert(ctx, false, "Rooms.update_room failed: #{outcome.message}")
  end

  return BDD.set(ctx, UPDATED, JSON.from("#{outcome.unwrap!}"))
end

def update_as(conn: Db.Connection, email: String, room_id: Int) -> Result[Bool]
  rows = try Db.query(conn, "select id from users where email_address = ?", [Db.Value.Text(email)])
  editor_id = value_int(rows[0].get("id", Db.Value.Null))
  return Rooms.update_room(conn, room_id, editor_id, "Renamed", false, [3], [1, 2])
end

# `Rooms.post` straight, as a person whose session the sign-in check let through before they were deactivated. The
# answer is kept as the update's: `false` is a refusal.
def ask_post(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| post_as(conn, args[0], args[2].to_i!, args[1]) end
  if not outcome.ok?
    return BDD.assert(ctx, false, "Rooms.post failed: #{outcome.message}")
  end

  return BDD.set(ctx, UPDATED, JSON.from("#{outcome.unwrap!}"))
end

def post_as(conn: Db.Connection, email: String, room_id: Int, body: String) -> Result[Bool]
  rows = try Db.query(conn, "select id from users where email_address = ?", [Db.Value.Text(email)])
  user_id = value_int(rows[0].get("id", Db.Value.Null))
  stored = try Rooms.post(conn, room_id, user_id, "stale-#{SecureRandom.hex(4)}", body)
  return ok(stored.some?)
end

def update_is_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, text_of(ctx, UPDATED) == "false", "the update said #{text_of(ctx, UPDATED)}")
end

# `Accounts` straight, as the person with that email, skipping the check of the page, so that only the check inside the
# transaction can refuse it. `action` is `deactivate`, `reactivate`, `make_member` or `make_administrator` of the user
# `user_id`, or `regenerate` (which
# takes no user). The outcome is kept as `Changed` or `Refused` (and the others of `Accounts.Change`).
def ask_accounts(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| accounts_as(conn, args[0], args[1], args[2].to_i!) end
  if not outcome.ok?
    return BDD.assert(ctx, false, "Accounts.#{args[1]} failed: #{outcome.message}")
  end

  return BDD.set(ctx, CHANGED, JSON.from(outcome.unwrap!))
end

def accounts_as(conn: Db.Connection, email: String, action: String, user_id: Int) -> Result[String]
  rows = try Db.query(conn, "select id from users where email_address = ?", [Db.Value.Text(email)])
  actor_id = value_int(rows[0].get("id", Db.Value.Null))
  if action == "regenerate"
    done = try Accounts.regenerate_join_code(conn, actor_id)
    if done
      return ok("Changed")
    end

    return ok("Refused")
  end

  if action == "deactivate"
    return ok(change_name(try Accounts.deactivate(conn, actor_id, user_id)))
  end

  if action == "make_member" or action == "make_administrator"
    return ok(change_name(try Accounts.set_role(conn, actor_id, user_id, action == "make_administrator")))
  end

  return ok(change_name(try Accounts.reactivate(conn, actor_id, user_id)))
end

# `Bots` straight, which looks at the actor again inside its transaction: `action` is `create`, `rename`, `reset_key`
# or `deactivate` (`create` takes no bot). The outcome is kept as the `Accounts.Change` names it, as
# for `ask_accounts`.
def ask_bots(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| bots_as(conn, args[0], args[1], args[2].to_i!) end
  if not outcome.ok?
    return BDD.assert(ctx, false, "Bots.#{args[1]} failed: #{outcome.message}")
  end

  return BDD.set(ctx, CHANGED, JSON.from(outcome.unwrap!))
end

def bots_as(conn: Db.Connection, email: String, action: String, bot_id: Int) -> Result[String]
  rows = try Db.query(conn, "select id from users where email_address = ?", [Db.Value.Text(email)])
  actor_id = value_int(rows[0].get("id", Db.Value.Null))
  if action == "create"
    if try Bots.create(conn, actor_id, "Late")
      return ok("Changed")
    end

    return ok("Refused")
  end

  if action == "rename"
    return ok(change_name(try Bots.rename(conn, actor_id, bot_id, "Late")))
  end

  if action == "reset_key"
    return ok(change_name(try Bots.reset_key(conn, actor_id, bot_id)))
  end

  return ok(change_name(try Bots.deactivate(conn, actor_id, bot_id)))
end

def change_name(change: Accounts.Change) -> String
  case change
    Accounts.Change.Changed -> return "Changed"
    Accounts.Change.Unchanged -> return "Unchanged"
    Accounts.Change.Missing -> return "Missing"
    Accounts.Change.Refused -> return "Refused"
    Accounts.Change.Taken -> return "Taken"
  end
end

def change_is_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, text_of(ctx, CHANGED) == "Refused", "the change was #{text_of(ctx, CHANGED)}")
end

# `Auth.join_hashed` straight, which is `Auth.join` after its checks and its hashing: the code and the email are
# looked at again inside its transaction, and only a call that skips the first look reaches that.
def ask_join_hashed(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| Auth.join_hashed(conn, args[1], "Late", args[0], "scrypt$digest", "", "") end

  if not outcome.ok?
    return BDD.assert(ctx, false, "Auth.join_hashed failed: #{outcome.message}")
  end

  return BDD.set(ctx, JOINED, JSON.from(join_name(outcome.unwrap!)))
end

# `Auth.open_session` straight: `Auth.sign_in` checks `active` first, so only a person who is deactivated between that
# check and the insert reaches the condition of the insert, and a call that skips the check stands for that.
def ask_open_session(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| Auth.open_session(conn, args[0].to_i!, "", "") end
  if not outcome.ok?
    return BDD.assert(ctx, false, "Auth.open_session failed: #{outcome.message}")
  end

  return BDD.set(ctx, SESSION, JSON.from("#{outcome.unwrap!.some?}"))
end

def session_is_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, text_of(ctx, SESSION) == "false", "a session was opened")
end

def session_is_opened(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, text_of(ctx, SESSION) == "true", "no session was opened")
end

def join_name(outcome: Auth.JoinOutcome) -> String
  case outcome
    Auth.JoinOutcome.Joined(_) -> return "Joined"
    Auth.JoinOutcome.Gone -> return "Gone"
    Auth.JoinOutcome.Invalid(_) -> return "Invalid"
  end
end

def join_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, text_of(ctx, JOINED) == args[0], "the join was #{text_of(ctx, JOINED)}")
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

# Does what `ContentRemoval` does, in a given moment: `Bans.delete_next_message` until it has none to take.
def run_removal(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| take_messages(conn, args[0].to_i.unwrap!) end
  return BDD.assert(ctx, outcome.ok?, "the removal failed: #{outcome.message}")
end

def take_messages(conn: Db.Connection, user_id: Int) -> Result[Void]
  more = true
  while more
    gone = try Bans.delete_next_message(conn, user_id)
    more = gone.some?
  end

  return ok()
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

# The room is deleted by a task after the answer, so a scenario waits for the rows to go: the query is asked
# again every
# 50 milliseconds until it gives the count or the time is over.
def query_gives_within(ctx: BDD.Context, args: List[String]) -> BDD.Context
  wanted = args[1].to_i!
  waited = 0
  count = value_int(rows_of(ctx, args[0])[0].values[0])
  while count != wanted and waited < args[2].to_i!
    Task.sleep(50)
    waited += 50
    count = value_int(rows_of(ctx, args[0])[0].values[0])
  end

  return BDD.assert(ctx, count == wanted, "the query still gave #{count} after #{waited} milliseconds")
end

# The three calls of the deletion by hand, with a message posted by the maker of the room between the first and the
# last: a request that was already running when the room was taken away can do that, and the message must go with the
# room.
def ask_delete_between(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| delete_between(conn, args[0], args[1].to_i!) end
  return BDD.assert(ctx, outcome.ok? and outcome.unwrap!, "the deletion failed: #{outcome.message}")
end

def delete_between(conn: Db.Connection, email: String, room_id: Int) -> Result[Bool]
  rows = try Db.query(conn, "select id from users where email_address = ?", [Db.Value.Text(email)])
  user_id = value_int(rows[0].get("id", Db.Value.Null))
  if not try Rooms.destroy_later(conn, room_id, user_id)
    return ok(false)
  end

  try Rooms.post(conn, room_id, user_id, "late", "posted in between")
  while try Rooms.delete_next_message(conn, room_id)
    Task.sleep(0)
  end

  try Rooms.post(conn, room_id, user_id, "later", "posted after the loop")
  try Rooms.delete_room(conn, room_id)
  return ok(true)
end

# The first calls of the deletion by hand, which the task of the app makes one after the other: the room is taken away
# from its people and `count` messages go, each in a transaction of its own. The room and the rest of its messages are
# left, so that the scenario can do something else, in the app, before the deletion goes on.
def ask_delete_some(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = with_database(ctx) do |conn| delete_some(conn, args[0], args[1].to_i!, args[2].to_i!) end
  return BDD.assert(ctx, outcome.ok? and outcome.unwrap!, "the deletion failed: #{outcome.message}")
end

def delete_some(conn: Db.Connection, email: String, room_id: Int, count: Int) -> Result[Bool]
  rows = try Db.query(conn, "select id from users where email_address = ?", [Db.Value.Text(email)])
  user_id = value_int(rows[0].get("id", Db.Value.Null))
  if not try Rooms.destroy_later(conn, room_id, user_id)
    return ok(false)
  end

  for _ in (1..count).to_a
    try Rooms.delete_next_message(conn, room_id)
  end

  return ok(true)
end

# The database file of a Rails Campfire, as Rails made it (`fixtures/rails/make.sh`), copied to where the app looks for
# its own, so the app opens a database that was not made by it. A copy, since the app writes to what it opens.
def rails_database(ctx: BDD.Context, args: List[String]) -> BDD.Context
  copied = copy_fixture(Path.join([text_of(ctx, DB_DIR), "campfire.db"]).unwrap!)
  return BDD.assert(ctx, copied.ok?, "cannot copy the Rails database: #{copied.message}")
end

# A second copy that nothing opens but the specs, to set a schema that the app made beside the schema that Rails made.
def rails_copy(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = Path.join([text_of(ctx, DB_DIR), "rails.db"]).unwrap!
  copied = copy_fixture(path)
  if not copied.ok?
    return BDD.assert(ctx, false, "cannot copy the Rails database: #{copied.message}")
  end

  return BDD.set(ctx, RAILS_URL, JSON.from("sqlite:#{path}"))
end

def copy_fixture(to: String) -> Result[Void]
  return copy_file(RAILS_FIXTURE, to)
end

# A file of the repository (`from` is relative to where the specs run) copied to `to`.
def copy_file(relative: String, to: String) -> Result[Void]
  return copy_path(try Path.join([try Path.cwd(), relative]), to)
end

# The file at `source` copied to `to`.
def copy_path(source: String, to: String) -> Result[Void]
  from = try File.open(source, "read", FILE_MS)
  target = try File.open(to, "write", FILE_MS)
  copied = copy_bytes(from, target)
  _ = File.close(from, FILE_MS)
  _ = File.close(target, FILE_MS)
  return copied
end

def copy_bytes(from: FileHandle, target: FileHandle) -> Result[Void]
  while true
    chunk = try File.read_bytes(from, COPY_CHUNK, FILE_MS)
    if chunk.size == 0
      return ok()
    end

    try File.write_bytes(target, chunk, FILE_MS)
  end

  return ok()
end

# The folder of the stylesheet of the repository, as a full path: the program of the app does not run in it.
def assets_dir() -> String
  return Path.join([Path.cwd().unwrap!, "public/assets"]).unwrap!
end

# Where the app looks for the files of Active Storage: a folder of the scenario, which goes with its database.
def storage_dir(ctx: BDD.Context) -> String
  return Path.join([text_of(ctx, DB_DIR), "files"]).unwrap!
end

# The rows and the files that Rails 8 wrote for the avatar of user 1, put where the app looks for them.
def stored_avatar(ctx: BDD.Context, args: List[String]) -> BDD.Context
  stored = with_database(ctx) do |conn| store_avatar(conn, storage_dir(ctx)) end
  return BDD.assert(ctx, stored.ok?, "cannot store the avatar: #{stored.message}")
end

def store_avatar(conn: Db.Connection, folder: String) -> Result[Void]
  statements = try File.read_text(AVATAR_SQL)
  for statement in statements.split("\n")
    if not statement.empty?
      try Db.execute(conn, statement, [])
    end
  end

  keys = try Db.query(conn, "select key from active_storage_blobs", [])
  for row in keys
    try store_blob_file(folder, value_text(row.get("key", Db.Value.Null)))
  end

  return ok()
end

# The file of one blob in the folders of the Disk service: `xx/yy/KEY`.
def store_blob_file(folder: String, key: String) -> Result[Void]
  first = key.slice(0, 2)
  second = key.slice(2, 2)
  try Dir.mkdir(try Path.join([folder, first, second]))
  return copy_file(try Path.join([AVATAR_STORAGE, first, second, key]), try Path.join([folder, first, second, key]))
end

# The file of a blob key in the storage folder is there (`kept`) or is not (`gone`).
def stored_file_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = Avatars.path(storage_dir(ctx), args[0])
  if path.none?
    return BDD.assert(ctx, false, "the key #{args[0]} is not one of Active Storage")
  end

  there = File.stat(path.unwrap!).ok?
  return BDD.assert(ctx, there == (args[1] == "kept"), "the file of #{args[0]} is #{args[1]}, expected: #{there}")
end

# The bytes that the app answered are the bytes of the image that was attached, before any variant.
def body_is_original(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = rows_of(
    ctx,
    "select blobs.key from active_storage_attachments avatars join active_storage_blobs blobs " +
    "on blobs.id = avatars.blob_id where avatars.record_type = 'User' and avatars.name = 'avatar' " +
    "and avatars.record_id = #{args[0]}",
  )

  if rows.empty?
    return BDD.assert(ctx, false, "the user #{args[0]} has no avatar")
  end

  path = Avatars.path(storage_dir(ctx), value_text(rows[0].values[0]))
  return HttpSteps.body_is_file(ctx, path.unwrap_or(""))
end

# The bytes that the app answered are the bytes of the WebP that Rails made for the variant of the avatar.
def body_is_variant(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = rows_of(
    ctx,
    "select variant_blobs.key from active_storage_attachments images " +
    "join active_storage_blobs variant_blobs on variant_blobs.id = images.blob_id " +
    "where images.record_type = 'ActiveStorage::VariantRecord' and images.name = 'image' " +
    "and variant_blobs.content_type = 'image/webp' and images.record_id in " +
    "(select variants.id from active_storage_variant_records variants join active_storage_attachments avatars " +
    "on avatars.blob_id = variants.blob_id where avatars.record_type = 'User' and avatars.record_id = #{args[0]})",
  )

  if rows.empty?
    return BDD.assert(ctx, false, "the user #{args[0]} has no stored variant")
  end

  key = value_text(rows[0].values[0])
  path = Avatars.path(storage_dir(ctx), key)
  if path.none?
    return BDD.assert(ctx, false, "the key #{key} is not one of Active Storage")
  end

  return HttpSteps.body_is_file(ctx, path.unwrap!)
end

# The columns, the indexes and the foreign keys of each table, as lines, from the database of `url`.
def shape_of(url: String, tables: List[String]) -> Result[List[String]]
  conn = try Db.open(url)
  lines: List[String] = []
  for table in tables
    shaped = table_shape(conn, table)
    if not shaped.ok?
      Db.close(conn)
      return error(shaped.message)
    end

    lines = lines.concat(shaped.unwrap!)
  end

  Db.close(conn)
  return ok(lines)
end

def table_shape(conn: Db.Connection, table: String) -> Result[List[String]]
  columns = try Db.query(conn, "pragma table_info(#{table})", [])
  indexes = try Db.query(conn, "pragma index_list(#{table})", [])
  keys = try Db.query(conn, "pragma foreign_key_list(#{table})", [])
  lines = columns.map do |row|
    name = shown(row, "name")
    kind = shown(row, "type")
    flags = "not-null #{shown(row, "notnull")} default #{shown(row, "dflt_value")} key #{shown(row, "pk")}"
    "#{table} column #{name} #{kind} #{flags}"
  end

  for index in indexes
    name = value_text(index.get("name", Db.Value.Null))
    parts = try Db.query(conn, "pragma index_info(#{name})", [])
    names = parts.map do |part| shown(part, "name") end
    lines = lines.push("#{table} index #{name} unique #{shown(index, "unique")} on #{names.join(",")}")
  end

  for key in keys
    lines = lines.push("#{table} key #{shown(key, "from")} to #{shown(key, "table")}.#{shown(key, "to")}")
  end

  # A virtual table (the FTS5 index) is its text: the module and the options, with the spacing and the quotes aside.
  virtual = try Db.query(
    conn,
    "select sql from sqlite_master where name = ? and sql like 'create virtual table%'",
    [Db.Value.Text(table)],
  )

  for row in virtual
    text = value_text(row.get("sql", Db.Value.Null)).downcase.replace(" ", "").replace("\"", "")
    lines = lines.push("#{table} virtual #{text}")
  end

  return ok(lines)
end

def shown(row: Db.Row, column: String) -> String
  case row.get(column, Db.Value.Null)
    Db.Value.Text(text) -> return text
    Db.Value.Int(number) -> return "#{number}"
    _ -> return "null"
  end
end

# The tables that a scenario names (`accounts, users, rooms`...) have, in a database that the app made, the same
# columns with the same types, the same indexes and the same keys as in the copy of the database that Rails made.
def tables_as_rails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  tables = args[0].split(",").map do |table| table.strip end
  ours = shape_of(text_of(ctx, DB_URL), tables)
  theirs = shape_of(text_of(ctx, RAILS_URL), tables)
  if not ours.ok? or not theirs.ok?
    return BDD.assert(ctx, false, "cannot read the tables: #{ours.message} #{theirs.message}")
  end

  # A table has the same columns in any order, and the indexes in the order that SQLite lists them.
  mine = ours.unwrap!.sort
  rails = theirs.unwrap!.sort
  return BDD.assert(ctx, mine == rails, "the app has\n#{mine.join("\n")}\nand Rails has\n#{rails.join("\n")}")
end

# Every table of the app is a table that Rails made, but for the ones that the scenario names. The tables that
# SQLite and Rails keep for themselves (the shadow tables of the FTS5 index, `ar_internal_metadata` and
# `schema_migrations`) are left out, since the app never makes them.
def tables_of_rails_and(ctx: BDD.Context, args: List[String]) -> BDD.Context
  ours = table_names(text_of(ctx, DB_URL))
  theirs = table_names(text_of(ctx, RAILS_URL))
  if not ours.ok? or not theirs.ok?
    return BDD.assert(ctx, false, "cannot read the tables: #{ours.message} #{theirs.message}")
  end

  extra = args[0].split(",").map do |name| name.strip end
  mine = ours.unwrap!.select do |name| not extra.include?(name) end
  return BDD.assert(ctx, mine == theirs.unwrap!, "the app has #{ours.unwrap!} and Rails has #{theirs.unwrap!}")
end

def table_names(url: String) -> Result[List[String]]
  conn = try Db.open(url)
  rows = Db.query(
    conn,
    "select name from sqlite_master where type = 'table' and name not like 'sqlite_%' " +
    "and name not like 'message_search_index_%' and name not in ('ar_internal_metadata', 'schema_migrations') " +
    "order by name",
    [],
  )

  Db.close(conn)
  return ok((try rows).map do |row| value_text(row.get("name", Db.Value.Null)) end)
end

def lacks_table(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = rows_of(ctx, "select name from sqlite_master where type = 'table'")
  names = rows.map do |row| value_text(row.get("name", Db.Value.Null)) end
  return BDD.assert(ctx, not names.include?(args[0]), "the database has the table #{args[0]}")
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

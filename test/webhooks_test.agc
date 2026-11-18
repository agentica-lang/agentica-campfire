import Db from "pkg/db/db"
import Jobs from "pkg/jobs/jobs"
import Logger from "std/logger"
import Accounts from "../src/campfire/accounts"
import Bots from "../src/campfire/bots"
import Config from "../src/campfire/config"
import Database from "../src/campfire/repo/database"
import Rails from "../src/campfire/repo/rails"
import Rooms from "../src/campfire/rooms"
import CableWeb from "../src/campfire_web/cable"
import Webhooks from "../src/campfire_web/webhooks"

private

SECRET = "0123456789abcdef0123456789abcdef"
WAIT_MS = 5_000
# Nothing listens on port 1, so a connection to it is refused at once.
REFUSED = "http://127.0.0.1:1/robo"
BOT_ID = 2

struct Site
  pool: Database.Pool
  cable: CableWeb.Cable
  hooks: Webhooks.Hooks
  clock: Jobs.Clock
  room: Rooms.Room
  message: Rooms.Message
end

# A database with Ana, the room "All Talk", the bot Robo whose webhook refuses connections, and a message of Ana that
# mentions Robo; the webhooks have no consumers, so the test runs their jobs with `Jobs.drain`.
def with_site(body: Fn[Site, Result[Void]]) -> Result[Void]
  root = System.env("TMPDIR").unwrap_or("/tmp")
  dir = try Path.join([root, "campfire-webhooks-#{OpenSSL.Random.hex(8)}"])
  try Dir.mkdir_private(dir)
  outcome = on_site(dir, body)
  removed = Path.remove(dir)
  try outcome
  removed
end

def on_site(dir: String, body: Fn[Site, Result[Void]]) -> Result[Void]
  parsed = try Config.parse(Config.DEFAULT_HOST, Config.DEFAULT_PORT, dir, "sqlite:#{dir}/campfire.db", SECRET)
  config = parsed.with(webhook_private_addresses: true, webhook_timeout_ms: WAIT_MS)
  _ = try Database.migrate(config.database_url)
  pool = try Database.open_pool(config.database_url, 2, WAIT_MS)
  cable = CableWeb.start(config, pool, none)
  if not cable.ok?
    Database.close_pool(pool)
    return error(cable.message)
  end

  clock = Jobs.manual_clock()
  hooks = Webhooks.start(config, pool, cable.unwrap!, Webhooks.Options(clock: some(clock.now), consumers: false))
  outcome = case hooks
    ok(started) -> seeded(pool, cable.unwrap!, started, clock, body)
    error(e) -> error(e)
  end

  case hooks
    ok(started) -> Webhooks.stop(started)
    error(_) -> nil
  end

  CableWeb.stop(cable.unwrap!)
  Database.close_pool(pool)
  outcome
end

def seeded(
  pool: Database.Pool,
  cable: CableWeb.Cable,
  hooks: Webhooks.Hooks,
  clock: Jobs.Clock,
  body: Fn[Site, Result[Void]],
) -> Result[Void]
  site = try Database.with_connection(pool) do |db|
    # Ana is made by hand: the first run would hash a password, which is slow.
    _ = try Db.execute(
      db,
      "insert into users (name, email_address, password_digest, role, created_at, updated_at) " +
      "values ('Ana', 'ana@example.com', 'x', 1, #{Rails.NOW}, #{Rails.NOW})",
      [],
    )

    _ = try Rooms.create_open(db, 1, "All Talk")
    try Test.assert(try Bots.create(db, 1, "Robo", REFUSED), "Robo was not made")
    message = try Rooms.post(db, 1, 1, "first", "@Robo hello", typed: true)
    room = try Rooms.find(db, 1, 1)
    ok(Site(pool: pool, cable: cable, hooks: hooks, clock: clock, room: room.unwrap!, message: message.unwrap!))
  end

  _ = Logger.detach("console")
  body.call(site)
end

def drain(site: Site, queue: String, due: Jobs.Due, max_runs: Int = 100) -> Result[Jobs.Drained]
  options = Jobs.Drain(
    queue: queue,
    due: due,
    max_runs: max_runs,
    clock: some(site.clock),
    backoff: some(&Webhooks.backoff),
  )

  Jobs.drain(site.hooks.delivery.backend, options, Webhooks.handler(site.hooks.delivery, queue))
end

# The message is fanned out to one post for Robo.
def fanned_out(site: Site) -> Result[Void]
  Webhooks.deliver_later(site.hooks, site.room, site.message)
  fanned = try drain(site, Webhooks.FAN_OUT, Jobs.Due.Ready)
  Test.eq(fanned, Jobs.Drained(done: 1, retried: 0, dead: 0))
end

def set_webhook(site: Site, url: String) -> Result[Int]
  Database.with_connection(site.pool) do |db|
    Db.execute(db, "update webhooks set url = ? where user_id = ?", [Db.Value.Text(url), Db.Value.Int(BOT_ID)])
  end
end

# A webhook on 127.0.0.1 that answers one post with 204 and gives its request line and body.
def serve_once(listener: TCP.Listener) -> Result[String]
  socket = try TCP.accept(listener, WAIT_MS)
  head = try TCP.read_line(socket, WAIT_MS)
  length = 0
  line = try TCP.read_line(socket, WAIT_MS)
  while line != ""
    if line.downcase.start_with?("content-length:")
      length = try line.split(":")[1].strip.to_i
    end

    line = try TCP.read_line(socket, WAIT_MS)
  end

  body = ""
  while body.bytes.length < length
    body += try String.from_bytes(try TCP.recv_bytes(socket, length - body.bytes.length, WAIT_MS))
  end

  try TCP.send(socket, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", WAIT_MS)
  TCP.close(socket)
  ok("#{head}\n#{body}")
end

def refused_until_dead(site: Site) -> Result[Void]
  try fanned_out(site)
  try Test.eq(try drain(site, Webhooks.POST, Jobs.Due.Ready), Jobs.Drained(done: 0, retried: 1, dead: 0))
  site.clock.advance.call(Webhooks.backoff(1) - 1)
  try Test.eq(try drain(site, Webhooks.POST, Jobs.Due.Ready), Jobs.Drained(done: 0, retried: 0, dead: 0))
  site.clock.advance.call(1)
  try Test.eq(try drain(site, Webhooks.POST, Jobs.Due.Ready), Jobs.Drained(done: 0, retried: 1, dead: 0))
  site.clock.advance.call(Webhooks.backoff(2))
  Test.eq(try drain(site, Webhooks.POST, Jobs.Due.Ready), Jobs.Drained(done: 0, retried: 0, dead: 1))
end

# The job holds ids, so a webhook that an administrator fixes after a refused connection gets the next attempt, and
# the key of the bot is read from the database for the payload.
def fixed_webhook_gets_the_retry(site: Site) -> Result[Void]
  try fanned_out(site)
  first = try drain(site, Webhooks.POST, Jobs.Due.Ready)
  try Test.eq(first, Jobs.Drained(done: 0, retried: 1, dead: 0))
  listener = try TCP.listen("127.0.0.1", 0)
  peer = Task.spawn(&serve_once, listener)
  _ = try set_webhook(site, "http://127.0.0.1:#{TCP.local_port(listener)}/fixed")
  second = drain(site, Webhooks.POST, Jobs.Due.All)
  seen = Task.await(peer)
  TCP.close_listener(listener)
  try Test.eq(try second, Jobs.Drained(done: 1, retried: 0, dead: 0))
  request = try seen
  try Test.assert(request.start_with?("POST /fixed HTTP/1.1"), request)
  try Test.assert(request.include?("\"plain\":\"hello\""), request)
  key = Database.with_connection(site.pool) do |db| Bots.hook(db, BOT_ID) end
  Test.assert(request.include?("/rooms/1/#{(try key).unwrap!.key}/messages"), request)
end

def gone_bot_is_dropped(site: Site) -> Result[Void]
  try fanned_out(site)
  changed = try Database.with_connection(site.pool) do |db| Bots.deactivate(db, 1, BOT_ID) end
  try Test.eq(changed, Accounts.Change.Changed)
  posted = try drain(site, Webhooks.POST, Jobs.Due.All)
  Test.eq(posted, Jobs.Drained(done: 0, retried: 0, dead: 1))
end

def main() -> Void
  Test.run([
    Test.test(
      "a refused connection is tried again, PAUSE_MS times the attempt later, and is dead on its third attempt",
    ) do with_site(&refused_until_dead) end,
    Test.test("a webhook fixed after a refused connection gets the next attempt, with the key read again") do
      with_site(&fixed_webhook_gets_the_retry)
    end,
    Test.test("the post of a bot that was deactivated after the fan-out is dropped") do
      with_site(&gone_bot_is_dropped)
    end,
  ])
end

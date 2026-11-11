import Testing from "pkg/bond/testing"
import HTTP from "std/http"
import Config from "../src/campfire/config"
import Database from "../src/campfire/repo/database"
import Mailer from "../src/campfire/mail/mailer"
import CableWeb from "../src/campfire_web/cable"
import Web from "../src/campfire_web/web"

SECRET = "0123456789abcdef0123456789abcdef"
WAIT_MS = 5_000
CHECKOUT_MS = 50

# Holds the only connection of the pool until `release` says so, and says through `started` that it has it.
def hold(pool: Database.Pool, started: Channel[Bool], release: Channel[Bool]) -> Result[Bool]
  Database.with_connection(pool) do |_|
    try started.send(true, WAIT_MS)
    try release.recv(WAIT_MS)
    return ok(true)
  end
end

def probe(dir: String) -> Result[Void]
  config = try Config.parse(Config.DEFAULT_HOST, Config.DEFAULT_PORT, dir, "sqlite:#{dir}/campfire.db", SECRET)
  schema = try Database.migrate(config.database_url)
  # One connection, and a short wait for it. The pool belongs to the task of the test, which closes it.
  pool = try Database.open_pool(config.database_url, 1, CHECKOUT_MS)
  mailer = try Mailer.start(none, 1)
  cable = try CableWeb.start(config, pool, none)
  app = Web.build(config, pool, schema.version, mailer, cable)
  started: Channel[Bool] = Channel.new(1)
  release: Channel[Bool] = Channel.new(1)
  holder = Task.spawn do hold(pool, started, release) end
  try started.recv(WAIT_MS)
  # Every connection is taken, so the sign-in filter waits for one and gives up: busy, not broken.
  busy = Testing.request(app, "GET", "/")
  try release.send(true, WAIT_MS)
  held = Task.await(holder)
  after = Testing.request(app, "GET", "/")
  CableWeb.stop(cable)
  Database.close_pool(pool)
  try held
  try Test.eq(busy.status, 503)
  try Test.eq(HTTP.header_values(busy.headers, "retry-after"), ["1"])
  Test.eq(after.status, 302)
end

def main() -> Void
  Test.run([
    Test.test(
      "a request that waits too long for a connection is answered 503 with Retry-After, then the app serves",
    ) do
      root = System.env("TMPDIR").unwrap_or("/tmp")
      dir = try Path.join([root, "campfire-pool-#{OpenSSL.Random.hex(8)}"])
      try Dir.mkdir_private(dir)
      outcome = probe(dir)
      removed = Path.remove(dir)
      try outcome
      removed
    end,
  ])
end

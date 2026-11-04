import Bond from "pkg/bond/bond"
import Testing from "pkg/bond/testing"
import Db from "pkg/db/db"
import HTTP from "std/http"
import Config from "../src/campfire/config"
import Database from "../src/campfire/repo/database"
import Mailer from "../src/campfire/mail/mailer"
import RateLimit from "../src/campfire/rate_limit"
import Web from "../src/campfire_web/web"

SECRET = "0123456789abcdef0123456789abcdef"
ATTEMPTS = 10
WINDOW_MS = 180_000
FORM = [Header(name: "content-type", value: "application/x-www-form-urlencoded")]
FIRST_CLIENT = "203.0.113.9"
OTHER_CLIENT = "198.51.100.7"

# Runs `body` on a database file of its own, which goes away when it is done, passed or failed. The folder is made
# under TMPDIR so that a test never writes outside the place the run was given.
def in_folder(body: Fn[String, Result[Void]]) -> Result[Void]
  root = System.env("TMPDIR").unwrap_or("/tmp")
  dir = try Path.join([root, "campfire-test-#{SecureRandom.hex(8)}"])
  try Dir.mkdir_private(dir)
  outcome = body.call(dir)
  removed = Path.remove(dir)
  try outcome
  return removed
end

def app_in(dir: String) -> Result[Bond.App]
  config = try Config.parse(Config.DEFAULT_HOST, Config.DEFAULT_PORT, dir, "sqlite:#{dir}/campfire.db", SECRET)
  schema = try Database.migrate(config.database_url)
  mailer = try Mailer.start(none, 1)
  return ok(Web.build(config, schema.version, mailer))
end

# A post to the sign-in route with no password: the handler refuses it at once (400) without hashing, so the limit
# can be
# reached in no time. The limit counts it all the same, as it counts every post.
def attempt(app: Bond.App, client: String) -> HttpResponse
  return Testing.request_from(app, client, "POST", "/session", FORM, "email=nobody%40example.com")
end

def main() -> Void
  Test.run([
    Test.test("the 11th attempt from one address is a 429 with Retry-After, and another address is not affected") do
      in_folder() do |dir|
        app = try app_in(dir)
        statuses = (1..ATTEMPTS).to_a.map do |_| attempt(app, FIRST_CLIENT).status end
        try Test.assert(statuses.all? do |status| status != 429 end, "refused before the limit: #{statuses}")
        refused = attempt(app, FIRST_CLIENT)
        try Test.eq(refused.status, 429)
        wait = HTTP.header_values(refused.headers, "retry-after")
        try Test.eq(wait.size, 1)
        try Test.assert(wait[0].to_i.unwrap! > 0 and wait[0].to_i.unwrap! <= WINDOW_MS / 1000, "retry-after #{wait}")
        Test.assert(attempt(app, OTHER_CLIENT).status != 429, "another address was refused")
      end
    end,
    Test.test("a session keeps the address of the client that made it") do
      in_folder() do |dir|
        app = try app_in(dir)
        form = "name=Ana&email=ana%40example.com&password=correct+horse+battery"
        made = Testing.request_from(app, FIRST_CLIENT, "POST", "/first_run", FORM, form)
        try Test.eq(made.status, 302)
        conn = try Db.open("sqlite:#{dir}/campfire.db")
        queried = Db.query(conn, "select ip_address from sessions", [])
        Db.close(conn)
        rows = try queried
        try Test.eq(rows.size, 1)
        Test.eq(rows[0].get("ip_address", Db.Value.Null), Db.Value.Text(FIRST_CLIENT))
      end
    end,
    Test.test("a window ends after its time, and the first attempt after it starts another") do
      windows = RateLimit.new()
      first = (1..3).to_a.map do |n| RateLimit.hit(windows, "k", n * 1000, 2, 10_000) end
      try Test.eq(first, [0, 0, 8])
      try Test.eq(RateLimit.hit(windows, "other", 3000, 2, 10_000), 0)
      try Test.eq(RateLimit.hit(windows, "k", 11_000, 2, 10_000), 0)
      try Test.eq(RateLimit.hit(windows, "k", 11_500, 2, 10_000), 0)
      Test.eq(RateLimit.hit(windows, "k", 12_000, 2, 10_000), 9)
    end,
  ])
end

import Bond from "pkg/bond/bond"
import Testing from "pkg/bond/testing"
import Db from "pkg/db/db"
import HTTP from "std/http"
import Config from "../src/campfire/config"
import Database from "../src/campfire/repo/database"
import Mailer from "../src/campfire/mail/mailer"
import RateLimit from "../src/campfire/rate_limit"
import CableWeb from "../src/campfire_web/cable"
import Web from "../src/campfire_web/web"

SECRET = "0123456789abcdef0123456789abcdef"
ATTEMPTS = 10
WINDOW_MS = 180_000
FORM = [Header(name: "content-type", value: "application/x-www-form-urlencoded")]
FIRST_CLIENT = "203.0.113.9"
OTHER_CLIENT = "198.51.100.7"

## The folder of a test and the app that serves from its database.
struct Site
  dir: String
  app: Bond.App
end

# Runs `body` on an app with a database file of its own, which goes away when it is done, passed or failed. The folder
# is made under TMPDIR so that a test never writes outside the place the run was given. The pool belongs to the task
# of the test, which closes it before it returns.
def in_folder(body: Fn[Site, Result[Void]]) -> Result[Void]
  root = System.env("TMPDIR").unwrap_or("/tmp")
  dir = try Path.join([root, "campfire-test-#{SecureRandom.hex(8)}"])
  try Dir.mkdir_private(dir)
  outcome = serve(dir, body)
  removed = Path.remove(dir)
  try outcome
  return removed
end

def serve(dir: String, body: Fn[Site, Result[Void]]) -> Result[Void]
  config = try Config.parse(Config.DEFAULT_HOST, Config.DEFAULT_PORT, dir, "sqlite:#{dir}/campfire.db", SECRET)
  schema = try Database.migrate(config.database_url)
  pool = try Database.open_pool(config.database_url, config.db_pool_size, config.db_checkout_ms)
  mailer = Mailer.start(none, 1)
  if not mailer.ok?
    Database.close_pool(pool)
    return error(mailer.message)
  end

  cable = CableWeb.start(config, pool, none)
  if not cable.ok?
    Database.close_pool(pool)
    return error(cable.message)
  end

  built = Web.build(config, pool, schema.version, mailer.unwrap!, cable.unwrap!)
  outcome = body.call(Site(dir: dir, app: built))
  CableWeb.stop(cable.unwrap!)
  Database.close_pool(pool)
  return outcome
end

# A post with no password: the handler refuses it at once (400) without hashing, so the limit is reached in no time.
# The limit counts it all the same, as it counts every post to the route.
def attempt(app: Bond.App, client: String, target: String) -> HttpResponse
  return Testing.request_from(app, client, "POST", target, FORM, "email=nobody%40example.com")
end

# The cookie of the first administrator, so that a request is signed in and reaches the handlers of public routes.
def sign_up(app: Bond.App) -> Result[Header]
  form = "name=Ana&email=ana%40example.com&password=correct+horse+battery"
  made = Testing.request_from(app, FIRST_CLIENT, "POST", "/first_run", FORM, form)
  try Test.eq(made.status, 302)
  return ok(Header(name: "cookie", value: HTTP.header_values(made.headers, "set-cookie")[0].split(";")[0]))
end

def main() -> Void
  Test.run([
    Test.test("the 11th attempt from one address is a 429 with Retry-After, and another address is not affected") do
      in_folder() do |site|
        app = site.app
        statuses = (1..ATTEMPTS).to_a.map do |_| attempt(app, FIRST_CLIENT, "/session").status end
        try Test.assert(statuses.all? do |status| status != 429 end, "refused before the limit: #{statuses}")
        refused = attempt(app, FIRST_CLIENT, "/session")
        try Test.eq(refused.status, 429)
        wait = HTTP.header_values(refused.headers, "retry-after")
        try Test.eq(wait.size, 1)
        try Test.assert(wait[0].to_i.unwrap! > 0 and wait[0].to_i.unwrap! <= WINDOW_MS / 1000, "retry-after #{wait}")
        Test.assert(attempt(app, OTHER_CLIENT, "/session").status != 429, "another address was refused")
      end
    end,
    Test.test("no spelling of the path escapes the limit for a person who is signed in") do
      in_folder() do |site|
        app = site.app
        cookie = try sign_up(app)
        headers = FORM.concat([cookie])
        # Each spelling has an address of its own, so each one has to reach the limit by itself.
        spellings = {"/session/": "198.51.100.1", "//session": "198.51.100.2", "/session//": "198.51.100.3"}
        for target in spellings.keys
          client = spellings.get(target, "")
          for _ in 1..ATTEMPTS
            posted = Testing.request_from(app, client, "POST", target, headers, "email=x")
            try Test.assert(posted.status != 429, "#{target} was refused before the limit")
          end

          refused = Testing.request_from(app, client, "POST", target, headers, "email=x")
          try Test.eq(refused.status, 429)
        end

        ok()
      end
    end,
    Test.test("a session keeps the address of the client that made it") do
      in_folder() do |site|
        app = site.app
        form = "name=Ana&email=ana%40example.com&password=correct+horse+battery"
        made = Testing.request_from(app, FIRST_CLIENT, "POST", "/first_run", FORM, form)
        try Test.eq(made.status, 302)
        conn = try Db.open("sqlite:#{site.dir}/campfire.db")
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
    Test.test("an IPv6 address is one client by its /64, and a mapped IPv4 address is its IPv4 address") do
      try Test.eq(RateLimit.key_of("203.0.113.9"), "203.0.113.9")
      try Test.eq(RateLimit.key_of("::ffff:203.0.113.9"), "203.0.113.9")
      try Test.eq(RateLimit.key_of("2001:db8:0:1::5"), RateLimit.key_of("2001:db8:0:1:ffff:1:2:3"))
      try Test.eq(RateLimit.key_of("2001:db8::7"), RateLimit.key_of("2001:db8:0:0:1::"))
      try Test.eq(RateLimit.key_of("::1"), RateLimit.key_of("0:0:0:0:9::1"))
      Test.assert(RateLimit.key_of("2001:db8:0:1::5") != RateLimit.key_of("2001:db8:0:2::5"), "two /64s share a key")
    end,
    Test.test("a sweep drops the old windows and idle clients") do
      windows = RateLimit.new()
      try Test.eq(RateLimit.hit(windows, "a", 0, 1, 10_000), 0)
      try Test.eq(RateLimit.hit(windows, "a", 20_000, 1, 10_000), 0)
      try Test.eq(ATS.size(windows), 3)
      try Test.eq(RateLimit.hit(windows, "b", 40_000, 1, 10_000), 0)
      Test.eq(ATS.keys(windows).sort, ["b|c|0", "b|s", "sweep"])
    end,
    Test.test("a full table counts the new addresses together with a larger limit, and keeps the others' counts") do
      full = RateLimit.new()
      for number in 0...(RateLimit.MAX_ENTRIES / 2)
        ATS.put(full, "k#{number}|s", 0)
        ATS.put(full, "k#{number}|c|0", 1)
      end

      # Limit 1 and factor 10: ten new addresses pass, the 11th is told the end of the shared window.
      passed = (1..10).to_a.map do |n| RateLimit.hit(full, "new#{n}", 1000, 1, 10_000) end
      try Test.eq(passed, List.repeat(0, 10))
      try Test.eq(RateLimit.hit(full, "new11", 4000, 1, 10_000), 7)
      try Test.eq(RateLimit.hit(full, "k1", 1000, 5, 10_000), 0)
      try Test.eq(RateLimit.hit(full, "k1", 1000, 1, 10_000), 9)
      # The table grows by the overflow client only, however many addresses arrive.
      Test.assert(ATS.size(full) <= RateLimit.MAX_ENTRIES + 3, "the table grew past its cap")
    end,
  ])
end

import Config from "../src/config"

SECRET = "0123456789abcdef0123456789abcdef"

# `parse` with the defaults for the address and the folder, to test the secret and the flag.
def secret_and_flag(secret: String, secure_cookies: String) -> Result[Config.Config]
  return Config.parse(Config.DEFAULT_HOST, Config.DEFAULT_PORT, Config.DEFAULT_DATA_DIR, "", secret, secure_cookies)
end

# `parse` with the defaults for what a test does not name, and a good secret.
def parse(host: String, port: String, data_dir: String) -> Result[Config.Config]
  return Config.parse(host, port, data_dir, "", SECRET)
end

def main() -> Void
  Test.run([
    Test.test("a host and a port make a config, and the database is a file of the data folder by default") do
      Test.eq(
        Config.parse(" 0.0.0.0 ", " 8080 ", " var/campfire ", "", SECRET, "true"),
        ok(
          Config.Config(
            host: "0.0.0.0",
            port: 8080,
            data_dir: "var/campfire",
            database_url: "sqlite:var/campfire/campfire.db?fts5=required",
            session_secret: SECRET,
            secure_cookies: true,
          ),
        ),
      )
    end,
    Test.test("what is left out is the default") do
      Test.eq(
        secret_and_flag(SECRET, Config.DEFAULT_SECURE_COOKIES),
        ok(
          Config.Config(
            host: Config.DEFAULT_HOST,
            port: 3000,
            data_dir: Config.DEFAULT_DATA_DIR,
            database_url: "sqlite:data/campfire.db?fts5=required",
            session_secret: SECRET,
            secure_cookies: false,
          ),
        ),
      )
    end,
    Test.test("a database url is kept as it is") do
      Test.eq(
        Config.parse(Config.DEFAULT_HOST, "0", Config.DEFAULT_DATA_DIR, " sqlite:/srv/chat.db ", SECRET),
        ok(
          Config.Config(
            host: Config.DEFAULT_HOST,
            port: 0,
            data_dir: "data",
            database_url: "sqlite:/srv/chat.db",
            session_secret: SECRET,
            secure_cookies: false,
          ),
        ),
      )
    end,
    Test.test("a port that is not a number from 0 to 65535 is an error") do
      try Test.error?(parse("127.0.0.1", "http", Config.DEFAULT_DATA_DIR))
      try Test.error?(parse("127.0.0.1", "65536", Config.DEFAULT_DATA_DIR))
      try Test.error?(parse("127.0.0.1", "-1", Config.DEFAULT_DATA_DIR))
      Test.error?(parse("127.0.0.1", "", Config.DEFAULT_DATA_DIR))
    end,
    Test.test("an empty host, an empty data folder or a data folder with a ? is an error") do
      try Test.error?(parse("  ", Config.DEFAULT_PORT, Config.DEFAULT_DATA_DIR))
      try Test.error?(parse("127.0.0.1", "3000", "tmp/a?b"))
      Test.error?(parse("127.0.0.1", "3000", " "))
    end,
    Test.test("a session secret of less than 32 bytes, or none, is an error") do
      try Test.error?(Config.parse())
      try Test.error?(secret_and_flag("0123456789abcdef0123456789abcde", "false"))
      Test.ok?(secret_and_flag(SECRET, "false"))
    end,
    Test.test("the secure cookies flag is true or false") do
      try Test.error?(secret_and_flag(SECRET, "yes"))
      Test.ok?(secret_and_flag(SECRET, "true"))
    end,
  ])
end

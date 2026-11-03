import Config from "../src/config"

def main() -> Void
  Test.run([
    Test.test("a host and a port make a config, and the database is a file of the data folder by default") do
      Test.eq(
        Config.parse(" 0.0.0.0 ", " 8080 ", " var/campfire ", ""),
        ok(
          Config.Config(
            host: "0.0.0.0",
            port: 8080,
            data_dir: "var/campfire",
            database_url: "sqlite:var/campfire/campfire.db?fts5=required",
          ),
        ),
      )
    end,
    Test.test("a database url is kept as it is") do
      Test.eq(
        Config.parse("127.0.0.1", "0", "data", " sqlite:/srv/chat.db "),
        ok(Config.Config(host: "127.0.0.1", port: 0, data_dir: "data", database_url: "sqlite:/srv/chat.db")),
      )
    end,
    Test.test("a port that is not a number from 0 to 65535 is an error") do
      try Test.error?(Config.parse("127.0.0.1", "http", "data", ""))
      try Test.error?(Config.parse("127.0.0.1", "65536", "data", ""))
      try Test.error?(Config.parse("127.0.0.1", "-1", "data", ""))
      Test.error?(Config.parse("127.0.0.1", "", "data", ""))
    end,
    Test.test("an empty host or data folder is an error") do
      try Test.error?(Config.parse("  ", "3000", "data", ""))
      Test.error?(Config.parse("127.0.0.1", "3000", " ", ""))
    end,
  ])
end

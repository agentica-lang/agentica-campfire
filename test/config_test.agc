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
    Test.test("what is left out is the default, and a database url is kept as it is") do
      try Test.eq(
        Config.parse(),
        ok(
          Config.Config(
            host: Config.DEFAULT_HOST,
            port: 3000,
            data_dir: Config.DEFAULT_DATA_DIR,
            database_url: "sqlite:data/campfire.db?fts5=required",
          ),
        ),
      )

      Test.eq(
        Config.parse(Config.DEFAULT_HOST, "0", Config.DEFAULT_DATA_DIR, " sqlite:/srv/chat.db "),
        ok(Config.Config(host: Config.DEFAULT_HOST, port: 0, data_dir: "data", database_url: "sqlite:/srv/chat.db")),
      )
    end,
    Test.test("a port that is not a number from 0 to 65535 is an error") do
      try Test.error?(Config.parse("127.0.0.1", "http"))
      try Test.error?(Config.parse("127.0.0.1", "65536"))
      try Test.error?(Config.parse("127.0.0.1", "-1"))
      Test.error?(Config.parse("127.0.0.1", ""))
    end,
    Test.test("an empty host, an empty data folder or a data folder with a ? is an error") do
      try Test.error?(Config.parse("  "))
      try Test.error?(Config.parse("127.0.0.1", "3000", "tmp/a?b"))
      Test.error?(Config.parse("127.0.0.1", "3000", " "))
    end,
  ])
end

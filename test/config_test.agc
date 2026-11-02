import Config from "../src/config"

def main() -> Void
  Test.run([
    Test.test("a host and a port make a config") do
      Test.eq(Config.parse(" 0.0.0.0 ", " 8080 "), ok(Config.Config(host: "0.0.0.0", port: 8080)))
    end,
    Test.test("port 0 asks for a free port") do
      Test.eq(Config.parse("127.0.0.1", "0"), ok(Config.Config(host: "127.0.0.1", port: 0)))
    end,
    Test.test("a port that is not a number from 0 to 65535 is an error") do
      try Test.error?(Config.parse("127.0.0.1", "http"))
      try Test.error?(Config.parse("127.0.0.1", "65536"))
      try Test.error?(Config.parse("127.0.0.1", "-1"))
      Test.error?(Config.parse("127.0.0.1", ""))
    end,
    Test.test("an empty host is an error") do Test.error?(Config.parse("  ", "3000")) end,
  ])
end

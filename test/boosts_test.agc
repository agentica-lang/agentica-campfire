import Boosts from "../src/campfire/boosts"

def main() -> Void
  Test.run([
    Test.test("the column of a message query is read back as the boosts it holds, in order, with their text intact") do
      text = (
        "[{\"id\":2,\"booster_id\":7,\"booster\":\"Bea \\\"B\\\"\",\"content\":\"👍\",\"created_at\":\"2026-03-01T09:00:00.123Z\"}," +
        "{\"id\":5,\"booster_id\":3,\"booster\":\"Cy\",\"content\":\"<b>&\",\"created_at\":\"2026-03-01T09:00:01.000Z\"}]"
      )

      boosts = Boosts.parse(text)
      try Test.eq(boosts.size, 2)
      try Test.eq(
        boosts[0],
        Boosts.Boost(id: 2, booster_id: 7, booster: "Bea \"B\"", content: "👍", created_at: "2026-03-01T09:00:00.123Z"),
      )

      try Test.eq(boosts[1].content, "<b>&")
      try Test.eq(Boosts.parse("[]"), [])
      try Test.eq(Boosts.parse(""), [])
      Test.eq(Boosts.parse("not json"), [])
    end,
    Test.test("a boost is 1 to 16 characters, and an emoji with a variation selector is two") do
      try Test.eq(Boosts.content_problem("1234567890123456"), "")
      try Test.eq(Boosts.content_problem("❤️"), "")
      try Test.eq(Boosts.content_problem(""), "A boost is 1 to 16 characters")
      Test.eq(Boosts.content_problem("12345678901234567"), "A boost is 1 to 16 characters")
    end,
  ])
end

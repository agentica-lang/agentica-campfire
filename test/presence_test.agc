import Presence from "../src/campfire/presence"

private

def main() -> Void
  Test.run([
    Test.test("a person is connected after present and not before, in the room only") do
      table = Presence.new()
      try Test.assert(not Presence.connected?(table, 1, 7, 0), "before")
      Presence.present(table, 1, 7, 1, 0)
      try Test.assert(Presence.connected?(table, 1, 7, 1), "after")
      try Test.assert(not Presence.connected?(table, 2, 7, 1), "another room")
      Test.assert(not Presence.connected?(table, 1, 8, 1), "another person")
    end,
    Test.test("a person with two tabs is connected until the second one leaves") do
      table = Presence.new()
      Presence.present(table, 1, 7, 1, 0)
      Presence.present(table, 1, 7, 2, 10)
      try Test.eq(Presence.tabs(table, 1, 7, 20), 2)
      Presence.absent(table, 1, 7, 1, 30)
      try Test.assert(Presence.connected?(table, 1, 7, 40), "one tab left")
      Presence.absent(table, 1, 7, 2, 50)
      try Test.assert(not Presence.connected?(table, 1, 7, 60), "no tab left")
      Presence.absent(table, 1, 7, 2, 70)
      Test.eq(Presence.tabs(table, 1, 7, 80), 0)
    end,
    Test.test("a person who does not refresh stops being connected after the time to live, and refresh extends it") do
      table = Presence.new()
      Presence.present(table, 1, 7, 1, 0)
      try Test.assert(Presence.connected?(table, 1, 7, Presence.TTL_MS - 1), "inside the time")
      try Test.assert(not Presence.connected?(table, 1, 7, Presence.TTL_MS), "at the time")
      Presence.refresh(table, 1, 7, 1, Presence.TTL_MS - 1)
      try Test.assert(Presence.connected?(table, 1, 7, Presence.TTL_MS + 1000), "after a refresh")
      Test.eq(Presence.tabs(table, 1, 7, Presence.TTL_MS + 1000), 1)
    end,
    Test.test("a tab that comes after the time ran out is the first one again") do
      table = Presence.new()
      Presence.present(table, 1, 7, 1, 0)
      Presence.present(table, 1, 7, 2, 10)
      Presence.present(table, 1, 7, 3, Presence.TTL_MS * 2)
      Test.eq(Presence.tabs(table, 1, 7, Presence.TTL_MS * 2), 1)
    end,
    Test.test(
      "a repeat of present or absent on one connection counts once, and a refresh counts a tab that was not",
    ) do
      table = Presence.new()
      Presence.present(table, 1, 7, 1, 0)
      Presence.present(table, 1, 7, 1, 10)
      Presence.present(table, 1, 7, 2, 20)
      try Test.eq(Presence.tabs(table, 1, 7, 30), 2)
      Presence.absent(table, 1, 7, 1, 40)
      Presence.absent(table, 1, 7, 1, 50)
      try Test.eq(Presence.tabs(table, 1, 7, 60), 1)
      Presence.refresh(table, 1, 7, 3, 70)
      Test.eq(Presence.tabs(table, 1, 7, 80), 2)
    end,
  ])
end

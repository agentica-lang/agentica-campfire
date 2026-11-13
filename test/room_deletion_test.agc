import RoomDeletion from "../src/campfire_web/room_deletion"

private

BUSY = "sqlite error 5: database is locked"

# One try of a step that fails `failing` times with `message` and then works; the table counts the tries.
def attempt(tries: ATS[String, Int], failing: Int, message: String) -> Result[Int]
  n = tries.add("calls", 1)
  return error(message) if n <= failing

  ok(n)
end

# What `retry` gives for a step that fails `failing` times, and how many times it ran.
def outcome(failing: Int, message: String) -> Result[Int]
  tries: ATS[String, Int] = ATS.new()
  RoomDeletion.retry(5, 1) do attempt(tries, failing, message) end
end

def runs(failing: Int, message: String) -> Int
  tries: ATS[String, Int] = ATS.new()
  _ = RoomDeletion.retry(5, 1) do attempt(tries, failing, message) end
  tries.get("calls").unwrap_or(0)
end

def main() -> Void
  Test.run([
    Test.test("a busy database is tried again until the step works") do
      try Test.eq(outcome(2, BUSY).unwrap!, 3)
      try Test.eq(outcome(2, "pool error: checkout timed out").unwrap!, 3)
      Test.eq(outcome(4, BUSY).unwrap!, 5)
    end,
    Test.test("a busy database that stays busy gives up after the last try, with its message") do
      failed = outcome(99, BUSY)
      try Test.assert(not failed.ok?, "a step that never works was a success")
      try Test.eq(failed.message, BUSY)
      Test.eq(runs(99, BUSY), 5)
    end,
    Test.test("any other failure, and a pool that is closed, are not tried again") do
      try Test.eq(runs(99, "sqlite error 1: no such table"), 1)
      Test.eq(runs(99, "pool error: closed"), 1)
    end,
  ])
end

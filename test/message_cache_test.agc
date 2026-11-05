import Cache from "std/cache"
import MessageCache from "../src/campfire_web/message_cache"
import Rooms from "../src/campfire/rooms"

def stored(id: Int, body: String) -> Rooms.Stored
  return Rooms.Stored(
    id: id,
    author: "Ana",
    body: body,
    created_at: "2026-03-01T09:00:00.000Z",
    updated_at: "2026-03-01 09:00:00.000000",
  )
end

# The bytes that the cache holds, 0 when it is off.
def held(cache: Optional[Cache.Store]) -> Int
  case cache
    none -> return 0
    some(store) -> return Cache.bytes(store)
  end
end

def main() -> Void
  Test.run([
    Test.test("a message is rendered once: the same message again adds nothing, another body adds an entry") do
      cache = MessageCache.start(1)
      once = [stored(1, "<p>Hi</p>")]
      first = MessageCache.list(cache, once)
      bytes = held(cache)
      try Test.assert(bytes > 0, "nothing was cached")
      try Test.eq(MessageCache.list(cache, once), first)
      try Test.eq(held(cache), bytes)
      MessageCache.list(cache, [stored(1, "<p>Hi again</p>")])
      Test.assert(held(cache) > bytes, "a changed body did not make a new entry")
    end,
    Test.test("the markup is the same with the cache on and off, and 0 megabytes is no cache") do
      messages = [stored(1, "<p>Hi <b onclick=\"x()\">there</b></p>"), stored(2, "a & b")]
      try Test.assert(MessageCache.start(0).none?, "0 megabytes made a cache")
      try Test.eq(MessageCache.list(MessageCache.start(1), messages), MessageCache.list(none, messages))
      Test.eq(MessageCache.list(none, []), "")
    end,
  ])
end

import Cache from "std/cache"
import Boosts from "../src/campfire/boosts"
import MessageCache from "../src/campfire_web/message_cache"
import Rooms from "../src/campfire/rooms"

def stored(id: Int, body: String) -> Rooms.Stored
  Rooms.Stored(
    id: id,
    room_id: 1,
    creator_id: 1,
    author: "Ana",
    body: body,
    created_at: "2026-03-01T09:00:00.000Z",
    updated_at: "2026-03-01 09:00:00.000000",
    boosts: [],
  )
end

# The bytes that the cache holds, 0 when it is off.
def held(cache: Optional[Cache.Store]) -> Int
  case cache
    none -> 0
    some(store) -> Cache.bytes(store)
  end
end

def main() -> Void
  Test.run([
    Test.test("a message is rendered once: the same message again adds nothing, another body adds an entry") do
      cache = MessageCache.start(1)
      once = [stored(1, "<p>Hi</p>")]
      first = MessageCache.list(cache, once, 1, "member")
      bytes = held(cache)
      try Test.assert(bytes > 0, "nothing was cached")
      try Test.eq(MessageCache.list(cache, once, 1, "member"), first)
      try Test.eq(held(cache), bytes)
      MessageCache.list(cache, [stored(1, "<p>Hi again</p>")], 1, "member")
      Test.assert(held(cache) > bytes, "a changed body did not make a new entry")
    end,
    Test.test("a boost that appears or changes makes a new entry, though updated_at is the same") do
      cache = MessageCache.start(1)
      plain = stored(1, "<p>Hi</p>")
      MessageCache.list(cache, [plain], 1, "member")
      bytes = held(cache)
      boosted = plain.with(boosts: [Boosts.Boost(id: 1, booster_id: 2, booster: "Bea", content: "👍", created_at: "")])
      try Test.assert(MessageCache.list(cache, [boosted], 1, "member").include?("👍"), "the boost is not shown")
      try Test.assert(held(cache) > bytes, "a boost did not make a new entry")
      bytes = held(cache)
      other = plain.with(boosts: [Boosts.Boost(id: 1, booster_id: 2, booster: "Bea", content: "🔥", created_at: "")])
      try Test.assert(MessageCache.list(cache, [other], 1, "member").include?("🔥"), "the new text is not shown")
      Test.assert(held(cache) > bytes, "a changed boost did not make a new entry")
    end,
    Test.test("the link to the edit page is for the author and an administrator, and a viewer's entry is its own") do
      cache = MessageCache.start(1)
      one = [stored(1, "<p>Hi</p>")]
      link = "/rooms/1/messages/1/edit"
      try Test.assert(MessageCache.list(cache, one, 1, "member").include?(link), "the author has no link")
      try Test.assert(MessageCache.list(cache, one, 2, "administrator").include?(link), "an administrator has no link")
      other = MessageCache.list(cache, one, 2, "member")
      try Test.assert(not other.include?("/edit"), "another member has the link")
      Test.eq(MessageCache.list(none, one, 2, "member"), other)
    end,
    Test.test("the markup is the same with the cache on and off, and 0 megabytes is no cache") do
      messages = [stored(1, "<p>Hi <b onclick=\"x()\">there</b></p>"), stored(2, "a & b")]
      try Test.assert(MessageCache.start(0).none?, "0 megabytes made a cache")
      try Test.eq(
        MessageCache.list(MessageCache.start(1), messages, 1, "member"),
        MessageCache.list(none, messages, 1, "member"),
      )

      Test.eq(MessageCache.list(none, [], 1, "member"), "")
    end,
  ])
end

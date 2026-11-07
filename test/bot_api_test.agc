import AuthWeb from "../src/campfire_web/auth"

# The paths that skip the sign-in filter and the check of the site are the API of the bots and nothing a browser can
# reach, so the shape is checked on its own: the router reads the non-empty segments, and so does `bot_api?`.
def main() -> Void
  Test.run([
    Test.test("the list and the message of a room are the API, with any key") do
      try Test.assert(AuthWeb.bot_api?("/rooms/1/3-aaaaBBBB1111/messages"), "list")
      try Test.assert(AuthWeb.bot_api?("/rooms/1/3-aaaaBBBB1111/messages/7"), "message")
      try Test.assert(AuthWeb.bot_api?("/rooms/1/wrong/messages/"), "a trailing slash")
      Test.assert(AuthWeb.bot_api?("//rooms//1//wrong//messages"), "double slashes")
    end,
    Test.test("the boosts of a message and of one boost are the API, and nothing else of that length is") do
      try Test.assert(AuthWeb.bot_api?("/rooms/1/3-aaaaBBBB1111/messages/9/boosts"), "boosts")
      try Test.assert(AuthWeb.bot_api?("/rooms/1/3-aaaaBBBB1111/messages/9/boosts/4"), "a boost")
      try Test.assert(AuthWeb.bot_api?("//rooms/1/wrong//messages/9/boosts/"), "odd slashes")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/3-aaaaBBBB1111/messages/9/foo"), "6 segments, another resource")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/3-aaaaBBBB1111/messages/9/foo/4"), "7 segments, another resource")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/3-aaaaBBBB1111/messages/9/boosts/4/x"), "8 segments")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/messages/9/boosts"), "5 segments, no key")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/messages/9/boosts/4"), "6 segments, a message where the key is")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/messages/messages/9/boosts"), "a key named messages")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/key/other/9/boosts"), "not messages")
      Test.assert(not AuthWeb.bot_api?("/messages/9/boosts/4"), "the boosts of the browser")
    end,
    Test.test("a browser path is never the API, whatever its shape") do
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/messages"), "the messages of a room")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1//messages"), "an empty key is no key")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/messages/9"), "a message")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/messages/messages"), "a message named messages")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/messages/9/edit"), "the edit page")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/@9"), "the room around a message")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/key/messages/9/edit"), "a longer path")
      try Test.assert(not AuthWeb.bot_api?("/rooms/1/key/other"), "another resource")
      try Test.assert(not AuthWeb.bot_api?("/account/1/key/messages"), "another prefix")
      Test.assert(not AuthWeb.bot_api?("/"), "the home page")
    end,
    Test.test("only the post of a message of a room is left to its handler, however the router reads the path") do
      try Test.assert(AuthWeb.message_post?("POST", "/rooms/1/messages"), "the route")
      try Test.assert(AuthWeb.message_post?("POST", "/rooms/1/messages/"), "a trailing slash")
      try Test.assert(AuthWeb.message_post?("POST", "//rooms/1//messages"), "double slashes")
      try Test.assert(not AuthWeb.message_post?("GET", "/rooms/1/messages"), "the older messages")
      try Test.assert(not AuthWeb.message_post?("HEAD", "/rooms/1/messages"), "a head")
      try Test.assert(not AuthWeb.message_post?("POST", "/rooms/1/3-aaaaBBBB1111/messages"), "the API of the bots")
      try Test.assert(not AuthWeb.message_post?("POST", "/rooms/1/messages/5"), "a message")
      try Test.assert(not AuthWeb.message_post?("POST", "/rooms/1"), "the room")
      Test.assert(not AuthWeb.message_post?("POST", "/rooms/1/refresh"), "another resource of the room")
    end,
  ])
end

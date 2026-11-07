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
  ])
end

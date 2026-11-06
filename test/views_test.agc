import Rooms from "../src/campfire/rooms"
import Views from "../src/campfire_web/views"

def message() -> Rooms.Message
  return Rooms.Message(
    id: 7,
    room_id: 3,
    creator_id: 2,
    author: "Ana",
    body: "<p>Hi</p>",
    created_at: "2026-03-01T09:00:00.000Z",
  )
end

def main() -> Void
  Test.run([
    Test.test("the layout escapes the title and keeps the content that the caller made") do
      page = Views.layout("<b>x</b> & y", "<p>ok</p>")
      try Test.assert(page.include?("<title>&lt;b&gt;x&lt;/b&gt; &amp; y</title>"), page)
      Test.assert(page.include?("<p>ok</p>"), page)
    end,
    Test.test(
      "a message without controls is the markup of the benchmark byte for byte, and with them it adds the link",
    ) do
      plain = (
        "<div id=\"message_7\" data-message-id=\"7\" data-creator-id=\"2\">\n" +
        "  <h3><strong>Ana</strong>\n" +
        "    <time datetime=\"2026-03-01T09:00:00.000Z\" title=\"2026-03-01T09:00:00.000Z\">09:00</time></h3>\n" +
        "  <turbo-frame id=\"edit_message_7\"><div id=\"presentation_message_7\"><p>Hi</p></div></turbo-frame></div>"
      )

      try Test.eq(Views.message(message(), false), plain)
      linked = Views.message(message(), true)
      try Test.assert(linked.include?("</time><a href=\"/rooms/3/messages/7/edit\">Edit</a></h3>"), linked)
      Test.eq(linked.replace("<a href=\"/rooms/3/messages/7/edit\">Edit</a>", ""), plain)
    end,
  ])
end

import Boosts from "../src/campfire/boosts"
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
    boosts: [],
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
      "a message without controls is the markup of the benchmark but for the boosts, and with them it adds the link",
    ) do
      plain = (
        "<div id=\"message_7\" data-message-id=\"7\" data-creator-id=\"2\">\n" +
        "  <h3><strong>Ana</strong>\n" +
        "    <time datetime=\"2026-03-01T09:00:00.000Z\" title=\"2026-03-01T09:00:00.000Z\">09:00</time></h3>\n" +
        "  <turbo-frame id=\"edit_message_7\"><div id=\"presentation_message_7\"><p>Hi</p></div>" +
        "<div id=\"boosts_message_7\"><a href=\"/messages/7/boosts/new\">Boost</a></div></turbo-frame></div>"
      )

      try Test.eq(Views.message(message(), false), plain)
      linked = Views.message(message(), true)
      try Test.assert(linked.include?("</time><a href=\"/rooms/3/messages/7/edit\">Edit</a></h3>"), linked)
      Test.eq(linked.replace("<a href=\"/rooms/3/messages/7/edit\">Edit</a>", ""), plain)
    end,
    Test.test("the streams of a new message are those of message_stream, with and without the controls") do
      room = Rooms.Room(id: 3, name: "Lobby", room_type: "Rooms::Open", creator_id: 2)
      streams = Views.message_streams(room, message())
      try Test.eq(streams.broadcast, Views.message_stream(room, message(), false))
      Test.eq(streams.own, Views.message_stream(room, message(), true))
    end,
    Test.test("a boost is written as text, with the form that takes it away, before the link that adds one") do
      one = Boosts.Boost(id: 5, booster_id: 2, booster: "Bea <b>", content: "<3 & more", created_at: "")
      html = Views.message(message().with(boosts: [one]), false)
      try Test.assert(html.include?("<div id=\"boost_5\" data-booster-id=\"2\"><small>Bea &lt;b&gt;</small>"), html)
      try Test.assert(html.include?("<span>&lt;3 &amp; more</span>"), html)
      try Test.assert(html.include?("<form method=\"post\" action=\"/messages/7/boosts/5\">"), html)
      try Test.assert(html.include?("value=\"delete\""), html)
      Test.assert(html.index_of("boost_5").unwrap! < html.index_of("/messages/7/boosts/new").unwrap!, html)
    end,
  ])
end

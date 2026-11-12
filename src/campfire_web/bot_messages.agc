## The messages API of the chat bots (`Messages::ByBotsController` of Rails): a bot lists the messages of a room, posts
## one, and edits or deletes its own, with its key (`ID-TOKEN`) in the path and JSON in the answers. The key is the
## whole login: these paths are not behind the sign-in filter (`AuthWeb.bot_api?`), no cookie is read, and nothing else
## of the request says who asks, so a page of another site has nothing to forge. Every answer is kept out of caches.
##
## The checks come in this order, and the first that fails is the answer: a key that names no active bot (a wrong one,
## one that a new token or a deactivation ended, a person's id) is 404, as is a room that the bot is not in and a room
## that does not exist (the same answer, so neither tells that the other exists), then a message that is not in the room
## (404), a message of somebody else (403), and last the request itself (400 for a cursor that is not a number or a body
## that is not UTF-8, 415 for a file upload, 422 for a body that is blank or too long).
##
## The boosts of a message (`Messages::Boosts::ByBotsController`) are on the same keys and in the same order: a bot
## boosts any message of the room (the raw body is the text, 1 to 16 characters once stripped) and takes off only its
## own boosts, and a boost of somebody else is as good as none (404).
##
## Where this differs from Rails: a wrong key is 404, not a redirect to the sign-in page, and a blank body is also
## refused on an edit. Left out until they exist here: the `attachment` upload (a `multipart/form-data` post is 415, so
## the form is never posted as text), the avatar of `creator` and of `booster` and the webhooks that a post sends to
## the bots it mentions.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Blocks from "blocks"
import Boosts from "../campfire/boosts"
import Bots from "../campfire/bots"
import CableWeb from "cable"
import Database from "../campfire/repo/database"
import HtmlSanitizer from "../campfire/html_sanitizer"
import Rooms from "../campfire/rooms"
import RoomsWeb from "rooms"
import Routes from "routes"
import {Config} from "../campfire/config"

# The segment of the paths that holds the key, and the name of the message and of the boost in them.
KEY = "segment"
MESSAGE = "message_id"
BOOST = "boost_id"

# Bytes of randomness in the `client_message_id` of a post (a bot sends none), which is that many bytes in hex.
CLIENT_ID_BYTES = 16

# The characters that `origin` takes in a `Host`: a name (`_` is in the service names of Docker and Kubernetes) or an
# IPv4 address, and the inside of an IPv6 address.
DIGITS = Set.new("0123456789".split(""))
HOST_CHARS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_".split(""))
HOST_V6_CHARS = Set.new("abcdefABCDEF0123456789:.".split(""))

UPLOAD_TYPE = "multipart/form-data"
UPLOAD_REFUSED = "Attachments are not supported yet"

# The role of a bot in `creator.role`; a bot only edits its own messages, so it is the role of the author of an edit.
BOT_ROLE = "bot"

struct Body
  plain_text: String
  html: String
end

struct Creator
  id: Int
  name: String
  role: String
end

struct RoomRef
  id: Int
end

# A message as `messages/_message.json.jbuilder` writes it, but for the `avatar_url` of the creator.
struct MessageJson
  id: Int
  created_at: String
  body: Body
  creator: Creator
  room: RoomRef
  url: String
end

# A boost as `messages/boosts/_boost.json.jbuilder` writes it, but for the `avatar_url` of the booster.
struct BoostJson
  id: Int
  content: String
  created_at: String
  booster: Creator
  message: MessageRef
end

struct MessageRef
  id: Int
  url: String
end

# The messages of a page and the query of the page that follows it ("" for none: `before=ID` or `after=ID`).
struct Window
  messages: List[Rooms.Stored]
  next: String
end

# Where a request for a message of the room ends up.
enum Located
  Missing
  Refused
  Found(Rooms.Stored)
end

# What a handler makes of its request, decided while its connection is open and answered after it is closed (the
# broadcast of a change waits for room in the hub, which the connection must not).
enum Answer
  Listed(Json, Int, String)
  Created(Rooms.Room, Rooms.Message, String)
  Edited(Rooms.Room, Rooms.Message, Json)
  Removed(Rooms.Room, Int)
  Boosted(Boosts.Reach, Boosts.Boost, Json)
  Unboosted(Boosts.Reach, Int)
  Refused(String)
  Unsupported
  NotFound
  Forbidden
end

## Adds the routes of the messages API to `app`. `cable` is where the changes are broadcast to the people who look at
## the room, and `config` says where the links of the answers start (`origin`).
export def add(app: Bond.App, pool: Database.Pool, cable: CableWeb.Cable, config: Config) -> Bond.App
  on_get_bot_messages = Blocks.handler() do |conn|
    serve(conn, pool, cable) do |db, bot, room| list_answer(conn, db, bot, room, origin(conn, config)) end
  end

  on_post_bot_messages = Blocks.handler() do |conn|
    serve(conn, pool, cable) do |db, bot, room| create_answer(conn, db, bot, room, config) end
  end

  on_patch_bot_message = Blocks.handler() do |conn|
    serve(conn, pool, cable) do |db, bot, room| edit_answer(conn, db, bot, room, config) end
  end

  on_put_bot_message = Blocks.handler() do |conn|
    serve(conn, pool, cable) do |db, bot, room| edit_answer(conn, db, bot, room, config) end
  end

  on_delete_bot_message = Blocks.handler() do |conn|
    serve(conn, pool, cable) do |db, bot, room| remove_answer(conn, db, bot, room) end
  end

  on_post_bot_message_boosts = Blocks.handler() do |conn|
    serve(conn, pool, cable) do |db, bot, room| boost_answer(conn, db, bot, room, origin(conn, config)) end
  end

  (
    app
    |> Bond.get(Routes.BOT_MESSAGES, on_get_bot_messages)
    |> Bond.post(Routes.BOT_MESSAGES, on_post_bot_messages)
    |> Bond.patch(Routes.BOT_MESSAGE, on_patch_bot_message)
    |> Bond.put(Routes.BOT_MESSAGE, on_put_bot_message)
    |> Bond.delete(Routes.BOT_MESSAGE, on_delete_bot_message)
    |> Bond.post(Routes.BOT_MESSAGE_BOOSTS, on_post_bot_message_boosts)
    |> Bond.delete(Routes.BOT_MESSAGE_BOOST) do |conn|
      serve(conn, pool, cable) do |db, bot, room| unboost_answer(conn, db, bot, room) end
    end
  )
end

## Where the links that the app writes for a client start: `CAMPFIRE_BASE_URL` when it is set, else the scheme of the
## app and the `Host` of the request. A `Host` that is not a host name or address with an optional port (letters,
## digits, `.` and `-`, or an IPv6 address in brackets) is left out, and so is a missing one: the links are then paths.
## The links go to the one who asked and are never stored or sent by email, but a `Host` with a byte that a header
## cannot carry would make the answer fail after the message is stored, and the bot would post it twice.
export def origin(conn: Bond.Conn, config: Config) -> String
  return config.base_url if config.base_url != ""

  host = Bond.request_header(conn, "host").unwrap_or("")
  return "" if not host_text?(host)

  return "https://#{host}" if config.secure_cookies

  "http://#{host}"
end

# `name`, `name:port`, `1.2.3.4:port` or `[v6]:port`, written with the characters of a host and nothing else.
def host_text?(host: String) -> Bool
  return false if host.empty?

  name = host
  port = ""
  if host.start_with?("[")
    close = host.index_of("]")
    return false if close.none?

    name = host.slice(1, close.unwrap! - 1)
    port = host.slice(close.unwrap! + 1, host.length - close.unwrap! - 1)
    return false if not port.empty? and not port.start_with?(":")

    return not name.empty? and name.split("").all? do |ch| HOST_V6_CHARS.include?(ch) end and port_text?(port)
  end

  at = host.index_of(":")
  if at.some?
    name = host.slice(0, at.unwrap!)
    port = host.slice(at.unwrap!, host.length - at.unwrap!)
  end

  not name.empty? and name.split("").all? do |ch| HOST_CHARS.include?(ch) end and port_text?(port)
end

# Nothing, or a colon and digits.
def port_text?(port: String) -> Bool
  return true if port.empty?

  digits = port.slice(1, port.length - 1)
  port.start_with?(":") and not digits.empty? and digits.split("").all? do |ch| DIGITS.include?(ch) end
end

# The key, then the room, with one connection of the pool for the work of `handle`; then the broadcast and the answer.
def serve(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  handle: Fn[Db.Connection, Bots.Bot, Rooms.Room, Result[Answer]],
) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| keyed(conn, db, handle) end
  ok(announced(conn, cable, answer))
end

def keyed(
  conn: Bond.Conn,
  db: Db.Connection,
  handle: Fn[Db.Connection, Bots.Bot, Rooms.Room, Result[Answer]],
) -> Result[Answer]
  found = try Bots.authenticate(db, Bond.param(conn, KEY).unwrap_or(""))
  case found
    none -> ok(Answer.NotFound)
    some(bot) -> in_room(conn, db, bot, handle)
  end
end

def in_room(
  conn: Bond.Conn,
  db: Db.Connection,
  bot: Bots.Bot,
  handle: Fn[Db.Connection, Bots.Bot, Rooms.Room, Result[Answer]],
) -> Result[Answer]
  id = Bond.param_int(conn, "id")
  return ok(Answer.NotFound) if not id.ok?

  room = try Rooms.find(db, bot.id, id.unwrap!)
  case room
    none -> ok(Answer.NotFound)
    some(found) -> handle.call(db, bot, found)
  end
end

def list_answer(conn: Bond.Conn, db: Db.Connection, bot: Bots.Bot, room: Rooms.Room, origin: String) -> Result[Answer]
  before = try RoomsWeb.cursor(conn, "before")
  after = try RoomsWeb.cursor(conn, "after")
  window = try window_of(db, room.id, before, after)
  case window
    none -> ok(Answer.NotFound)
    some(page) -> listed(db, bot, room, origin, page)
  end
end

def listed(db: Db.Connection, bot: Bots.Bot, room: Rooms.Room, origin: String, page: Window) -> Result[Answer]
  roles = try Rooms.author_roles(db, page.messages)
  total = try Rooms.message_count(db, room.id)
  messages = page.messages.map do |stored|
    message_json(origin, Rooms.clean(stored), roles.get(stored.creator_id, "member"))
  end

  link = ""
  if page.next != ""
    link = "#{origin}#{Routes.bot_messages_path(room.id, bot.key)}?#{page.next}"
  end

  ok(Answer.Listed(JSON.from(messages), total, link))
end

# The messages that the query asks for, as `find_paged_messages` of Rails picks them: `before` wins over `after`, and
# with neither the newest page. A cursor that is no message of the room is `none`, which is a 404 as `find`
# raises there.
def window_of(db: Db.Connection, room_id: Int, before: Optional[Int], after: Optional[Int]) -> Result[Optional[Window]]
  return older_window(db, room_id, before) if before.some?

  return newer_window(db, room_id, after.unwrap!) if after.some?

  older_window(db, room_id, none)
end

def older_window(db: Db.Connection, room_id: Int, before: Optional[Int]) -> Result[Optional[Window]]
  if before.some?
    anchor = try Rooms.find_message(db, room_id, before.unwrap!)
    return ok(none) if anchor.none?
  end

  page = try Rooms.page(db, room_id, before)
  next = ""
  if page.older.some?
    next = "before=#{page.older.unwrap!}"
  end

  ok(some(Window(messages: page.messages, next: next)))
end

def newer_window(db: Db.Connection, room_id: Int, after: Int) -> Result[Optional[Window]]
  anchor = try Rooms.find_message(db, room_id, after)
  return ok(none) if anchor.none?

  messages = try Rooms.page_after(db, room_id, after)
  next = ""
  if not messages.empty?
    more = try Rooms.newer?(db, room_id, messages.last.id)
    if more
      next = "after=#{messages.last.id}"
    end
  end

  ok(some(Window(messages: messages, next: next)))
end

def create_answer(
  conn: Bond.Conn,
  db: Db.Connection,
  bot: Bots.Bot,
  room: Rooms.Room,
  config: Config,
) -> Result[Answer]
  return ok(Answer.Unsupported) if upload?(conn)

  body = (try Bond.body_text(conn)).strip
  problem = Rooms.body_problem(body, config.max_message_length)
  return ok(Answer.Refused(problem)) if problem != ""

  # The body is the HTML of the message, as Action Text takes it in Rails; `Rooms.post` cleans it. A post stores
  # nothing for a bot that was deactivated since the key was checked, nor in a room that was deleted since: the key is
  # gone too.
  stored = try Rooms.post(db, room.id, bot.id, OpenSSL.Random.hex(CLIENT_ID_BYTES), body)
  case stored
    none -> ok(Answer.NotFound)
    some(message) -> ok(Answer.Created(room, message, message_url(origin(conn, config), room.id, message.id)))
  end
end

def edit_answer(conn: Bond.Conn, db: Db.Connection, bot: Bots.Bot, room: Rooms.Room, config: Config) -> Result[Answer]
  located = try own_message(conn, db, bot, room)
  case located
    Located.Missing -> ok(Answer.NotFound)
    Located.Refused -> ok(Answer.Forbidden)
    Located.Found(message) -> saved(conn, db, bot, room, config, message)
  end
end

def saved(
  conn: Bond.Conn,
  db: Db.Connection,
  bot: Bots.Bot,
  room: Rooms.Room,
  config: Config,
  message: Rooms.Stored,
) -> Result[Answer]
  return ok(Answer.Unsupported) if upload?(conn)

  body = (try Bond.body_text(conn)).strip
  problem = Rooms.body_problem(body, config.max_message_length)
  return ok(Answer.Refused(problem)) if problem != ""

  changed = try Rooms.update_message(db, room.id, message.id, bot.id, body)
  return ok(Answer.NotFound) if not changed

  # The message as it is stored now, which is what the people who look at the room are shown.
  stored = try Rooms.find_message(db, room.id, message.id)
  return ok(Answer.NotFound) if stored.none?

  edited = Rooms.clean(stored.unwrap!)
  ok(Answer.Edited(room, edited, JSON.from(message_json(origin(conn, config), edited, BOT_ROLE))))
end

def remove_answer(conn: Bond.Conn, db: Db.Connection, bot: Bots.Bot, room: Rooms.Room) -> Result[Answer]
  located = try own_message(conn, db, bot, room)
  case located
    Located.Missing -> ok(Answer.NotFound)
    Located.Refused -> ok(Answer.Forbidden)
    Located.Found(message) -> removed(db, bot, room, message)
  end
end

def removed(db: Db.Connection, bot: Bots.Bot, room: Rooms.Room, message: Rooms.Stored) -> Result[Answer]
  gone = try Rooms.delete_message(db, room.id, message.id, bot.id)
  return ok(Answer.NotFound) if not gone

  ok(Answer.Removed(room, message.id))
end

# The message that the path names, when it is in the room and the bot wrote it. A bot is never an administrator, so the
# author is the only right it has over a message (`User#can_administer?`). The checks inside `Rooms` look again.
def own_message(conn: Bond.Conn, db: Db.Connection, bot: Bots.Bot, room: Rooms.Room) -> Result[Located]
  stored = try room_message(conn, db, room)
  case stored
    none -> ok(Located.Missing)
    some(one) if one.creator_id != bot.id -> ok(Located.Refused)
    some(one) -> ok(Located.Found(one))
  end
end

# The message that the path names, when it is in the room, whoever wrote it.
def room_message(conn: Bond.Conn, db: Db.Connection, room: Rooms.Room) -> Result[Optional[Rooms.Stored]]
  id = Bond.param_int(conn, MESSAGE)
  return ok(none) if not id.ok?

  Rooms.find_message(db, room.id, id.unwrap!)
end

def boost_answer(conn: Bond.Conn, db: Db.Connection, bot: Bots.Bot, room: Rooms.Room, origin: String) -> Result[Answer]
  stored = try room_message(conn, db, room)
  case stored
    none -> ok(Answer.NotFound)
    some(message) -> boosted(conn, db, bot, room, origin, message)
  end
end

def boosted(
  conn: Bond.Conn,
  db: Db.Connection,
  bot: Bots.Bot,
  room: Rooms.Room,
  origin: String,
  message: Rooms.Stored,
) -> Result[Answer]
  return ok(Answer.Unsupported) if upload?(conn)

  content = (try Bond.body_text(conn)).strip
  problem = Boosts.content_problem(content)
  return ok(Answer.Refused(problem)) if problem != ""

  # Nothing is stored for a bot that was deactivated since the key was checked, nor for a message that was deleted.
  added = try Boosts.add(db, bot.id, message.id, content)
  case added
    none -> ok(Answer.NotFound)
    some(boost) ->
      reach = Boosts.Reach(message_id: message.id, room_id: room.id)
      ok(Answer.Boosted(reach, boost, JSON.from(boost_json(origin, bot, boost, reach))))
  end
end

def unboost_answer(conn: Bond.Conn, db: Db.Connection, bot: Bots.Bot, room: Rooms.Room) -> Result[Answer]
  stored = try room_message(conn, db, room)
  case stored
    none -> ok(Answer.NotFound)
    some(message) -> unboosted(conn, db, bot, room, message)
  end
end

def unboosted(
  conn: Bond.Conn,
  db: Db.Connection,
  bot: Bots.Bot,
  room: Rooms.Room,
  message: Rooms.Stored,
) -> Result[Answer]
  id = Bond.param_int(conn, BOOST)
  return ok(Answer.NotFound) if not id.ok?

  gone = try Boosts.remove(db, bot.id, message.id, id.unwrap!)
  return ok(Answer.NotFound) if not gone

  ok(Answer.Unboosted(Boosts.Reach(message_id: message.id, room_id: room.id), id.unwrap!))
end

# A file upload (`curl -F attachment=@file`) is a form that would be posted as the text of the message.
def upload?(conn: Bond.Conn) -> Bool
  type = Bond.request_header(conn, "content-type").unwrap_or("")
  type.downcase.start_with?(UPLOAD_TYPE)
end

def message_json(origin: String, message: Rooms.Message, role: String) -> MessageJson
  MessageJson(
    id: message.id,
    created_at: message.created_at,
    body: Body(plain_text: HtmlSanitizer.plain_text_of_clean(message.body), html: message.body),
    creator: Creator(id: message.creator_id, name: message.author, role: role),
    room: RoomRef(id: message.room_id),
    url: message_url(origin, message.room_id, message.id),
  )
end

def boost_json(origin: String, bot: Bots.Bot, boost: Boosts.Boost, reach: Boosts.Reach) -> BoostJson
  BoostJson(
    id: boost.id,
    content: boost.content,
    created_at: boost.created_at,
    booster: Creator(id: bot.id, name: boost.booster, role: BOT_ROLE),
    message: MessageRef(id: reach.message_id, url: message_url(origin, reach.room_id, reach.message_id)),
  )
end

def message_url(origin: String, room_id: Int, message_id: Int) -> String
  "#{origin}#{Routes.room_message_path(room_id, message_id)}"
end

def announced(conn: Bond.Conn, cable: CableWeb.Cable, answer: Answer) -> Bond.Conn
  case answer
    Answer.Created(room, message, _) -> CableWeb.message_created(cable, room, message)
    Answer.Edited(room, message, _) -> CableWeb.message_edited(cable, room, message)
    Answer.Removed(room, message_id) -> CableWeb.message_removed(cable, room.id, message_id)
    Answer.Boosted(reach, boost, _) -> CableWeb.boost_added(cable, reach.room_id, reach.message_id, boost)
    Answer.Unboosted(reach, boost_id) -> CableWeb.boost_removed(cable, reach.room_id, boost_id)
    _ -> return answered(conn, answer)
  end

  answered(conn, answer)
end

def answered(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  Bond.header(reply(conn, answer), "cache-control", "no-store")
end

def reply(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Listed(messages, total, link) ->
      page = Bond.header(Bond.json(conn, 200, messages), "x-total-count", total.to_s)
      return page if link == ""

      Bond.header(page, "link", "<#{link}>; rel=\"next\"")
    Answer.Created(_, _, location) -> Bond.header(Bond.status(conn, 201), "location", location)
    Answer.Edited(_, _, message) -> Bond.json(conn, 200, message)
    Answer.Removed(_, _) -> Bond.status(conn, 204)
    Answer.Boosted(_, _, boost) -> Bond.json(conn, 201, boost)
    Answer.Unboosted(_, _) -> Bond.status(conn, 204)
    Answer.Refused(problem) -> Bond.text(conn, 422, problem)
    Answer.Unsupported -> Bond.text(conn, 415, UPLOAD_REFUSED)
    Answer.NotFound -> Bond.text(conn, 404, Routes.MISSING)
    Answer.Forbidden -> Bond.text(conn, 403, "Forbidden")
  end
end

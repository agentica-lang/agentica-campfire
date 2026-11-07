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
## Where this differs from Rails: a wrong key is 404, not a redirect to the sign-in page, and a blank body is also
## refused on an edit. Left out until they exist here: the `attachment` upload (a `multipart/form-data` post is 415, so
## the form is never posted as text), the boosts of a message, the avatar of `creator` and the webhooks that a post
## sends to the bots it mentions.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Bots from "../campfire/bots"
import CableWeb from "cable"
import Database from "../campfire/repo/database"
import HtmlSanitizer from "../campfire/html_sanitizer"
import Rooms from "../campfire/rooms"
import RoomsWeb from "rooms"
import Routes from "routes"
import {Config} from "../campfire/config"

# The segment of the paths that holds the key, and the name of the message in them.
KEY = "segment"
MESSAGE = "message_id"

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
  Refused(String)
  Unsupported
  NotFound
  Forbidden
end

## Adds the routes of the messages API to `app`. `cable` is where the changes are broadcast to the people who look at
## the room, and `config` says where the links of the answers start (`origin`).
export def add(app: Bond.App, pool: Database.Pool, cable: CableWeb.Cable, config: Config) -> Bond.App
  return (
    app
    |> Bond.get(Routes.BOT_MESSAGES) do |conn|
      serve(conn, pool, cable) do |db, bot, room| list_answer(conn, db, bot, room, origin(conn, config)) end
    end
    |> Bond.post(Routes.BOT_MESSAGES) do |conn|
      serve(conn, pool, cable) do |db, bot, room| create_answer(conn, db, bot, room, origin(conn, config)) end
    end
    |> Bond.patch(Routes.BOT_MESSAGE) do |conn|
      serve(conn, pool, cable) do |db, bot, room| edit_answer(conn, db, bot, room, origin(conn, config)) end
    end
    |> Bond.put(Routes.BOT_MESSAGE) do |conn|
      serve(conn, pool, cable) do |db, bot, room| edit_answer(conn, db, bot, room, origin(conn, config)) end
    end
    |> Bond.delete(Routes.BOT_MESSAGE) do |conn|
      serve(conn, pool, cable) do |db, bot, room| remove_answer(conn, db, bot, room) end
    end
  )
end

## Where the links that the app writes for a client start: `CAMPFIRE_BASE_URL` when it is set, else the scheme of the
## app and the `Host` of the request. A `Host` that is not a host name or address with an optional port (letters,
## digits, `.` and `-`, or an IPv6 address in brackets) is left out, and so is a missing one: the links are then paths.
## The links go to the one who asked and are never stored or sent by email, but a `Host` with a byte that a header
## cannot carry would make the answer fail after the message is stored, and the bot would post it twice.
export def origin(conn: Bond.Conn, config: Config) -> String
  if config.base_url != ""
    return config.base_url
  end

  host = Bond.request_header(conn, "host").unwrap_or("")
  if not host_text?(host)
    return ""
  end

  if config.secure_cookies
    return "https://#{host}"
  end

  return "http://#{host}"
end

# `name`, `name:port`, `1.2.3.4:port` or `[v6]:port`, written with the characters of a host and nothing else.
def host_text?(host: String) -> Bool
  if host.empty?
    return false
  end

  name = host
  port = ""
  if host.start_with?("[")
    close = host.index_of("]")
    if close.none?
      return false
    end

    name = host.slice(1, close.unwrap! - 1)
    port = host.slice(close.unwrap! + 1, host.length - close.unwrap! - 1)
    if not port.empty? and not port.start_with?(":")
      return false
    end

    return not name.empty? and name.split("").all? do |ch| HOST_V6_CHARS.include?(ch) end and port_text?(port)
  end

  at = host.index_of(":")
  if at.some?
    name = host.slice(0, at.unwrap!)
    port = host.slice(at.unwrap!, host.length - at.unwrap!)
  end

  return not name.empty? and name.split("").all? do |ch| HOST_CHARS.include?(ch) end and port_text?(port)
end

# Nothing, or a colon and digits.
def port_text?(port: String) -> Bool
  if port.empty?
    return true
  end

  digits = port.slice(1, port.length - 1)
  return port.start_with?(":") and not digits.empty? and digits.split("").all? do |ch| DIGITS.include?(ch) end
end

# The key, then the room, with one connection of the pool for the work of `handle`; then the broadcast and the answer.
def serve(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  handle: Fn[Db.Connection, Bots.Bot, Rooms.Room, Result[Answer]],
) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| keyed(conn, db, handle) end
  return ok(announced(conn, cable, answer))
end

def keyed(
  conn: Bond.Conn,
  db: Db.Connection,
  handle: Fn[Db.Connection, Bots.Bot, Rooms.Room, Result[Answer]],
) -> Result[Answer]
  found = try Bots.authenticate(db, Bond.param(conn, KEY).unwrap_or(""))
  case found
    none -> return ok(Answer.NotFound)
    some(bot) -> return in_room(conn, db, bot, handle)
  end
end

def in_room(
  conn: Bond.Conn,
  db: Db.Connection,
  bot: Bots.Bot,
  handle: Fn[Db.Connection, Bots.Bot, Rooms.Room, Result[Answer]],
) -> Result[Answer]
  id = Bond.param_int(conn, "id")
  if not id.ok?
    return ok(Answer.NotFound)
  end

  room = try Rooms.find(db, bot.id, id.unwrap!)
  case room
    none -> return ok(Answer.NotFound)
    some(found) -> return handle.call(db, bot, found)
  end
end

def list_answer(conn: Bond.Conn, db: Db.Connection, bot: Bots.Bot, room: Rooms.Room, origin: String) -> Result[Answer]
  before = try RoomsWeb.cursor(conn, "before")
  after = try RoomsWeb.cursor(conn, "after")
  window = try window_of(db, room.id, before, after)
  case window
    none -> return ok(Answer.NotFound)
    some(page) -> return listed(db, bot, room, origin, page)
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

  return ok(Answer.Listed(JSON.from(messages), total, link))
end

# The messages that the query asks for, as `find_paged_messages` of Rails picks them: `before` wins over `after`, and
# with neither the newest page. A cursor that is no message of the room is `none`, which is a 404 as `find`
# raises there.
def window_of(db: Db.Connection, room_id: Int, before: Optional[Int], after: Optional[Int]) -> Result[Optional[Window]]
  if before.some?
    return older_window(db, room_id, before)
  end

  if after.some?
    return newer_window(db, room_id, after.unwrap!)
  end

  return older_window(db, room_id, none)
end

def older_window(db: Db.Connection, room_id: Int, before: Optional[Int]) -> Result[Optional[Window]]
  if before.some?
    anchor = try Rooms.find_message(db, room_id, before.unwrap!)
    if anchor.none?
      return ok(none)
    end
  end

  page = try Rooms.page(db, room_id, before)
  next = ""
  if page.older.some?
    next = "before=#{page.older.unwrap!}"
  end

  return ok(some(Window(messages: page.messages, next: next)))
end

def newer_window(db: Db.Connection, room_id: Int, after: Int) -> Result[Optional[Window]]
  anchor = try Rooms.find_message(db, room_id, after)
  if anchor.none?
    return ok(none)
  end

  messages = try Rooms.page_after(db, room_id, after)
  next = ""
  if not messages.empty?
    more = try Rooms.newer?(db, room_id, messages.last.id)
    if more
      next = "after=#{messages.last.id}"
    end
  end

  return ok(some(Window(messages: messages, next: next)))
end

def create_answer(
  conn: Bond.Conn,
  db: Db.Connection,
  bot: Bots.Bot,
  room: Rooms.Room,
  origin: String,
) -> Result[Answer]
  if upload?(conn)
    return ok(Answer.Unsupported)
  end

  body = (try Bond.body_text(conn)).strip
  problem = Rooms.body_problem(body)
  if problem != ""
    return ok(Answer.Refused(problem))
  end

  # The body is the HTML of the message, as Action Text takes it in Rails; `Rooms.post` cleans it. A post stores
  # nothing for a bot that was deactivated since the key was checked, nor in a room that was deleted since: the key is
  # gone too.
  stored = try Rooms.post(db, room.id, bot.id, SecureRandom.hex(CLIENT_ID_BYTES), body)
  case stored
    none -> return ok(Answer.NotFound)
    some(message) -> return ok(Answer.Created(room, message, message_url(origin, room.id, message.id)))
  end
end

def edit_answer(conn: Bond.Conn, db: Db.Connection, bot: Bots.Bot, room: Rooms.Room, origin: String) -> Result[Answer]
  located = try own_message(conn, db, bot, room)
  case located
    Located.Missing -> return ok(Answer.NotFound)
    Located.Refused -> return ok(Answer.Forbidden)
    Located.Found(message) -> return saved(conn, db, bot, room, origin, message)
  end
end

def saved(
  conn: Bond.Conn,
  db: Db.Connection,
  bot: Bots.Bot,
  room: Rooms.Room,
  origin: String,
  message: Rooms.Stored,
) -> Result[Answer]
  if upload?(conn)
    return ok(Answer.Unsupported)
  end

  body = (try Bond.body_text(conn)).strip
  problem = Rooms.body_problem(body)
  if problem != ""
    return ok(Answer.Refused(problem))
  end

  changed = try Rooms.update_message(db, room.id, message.id, bot.id, body)
  if not changed
    return ok(Answer.NotFound)
  end

  # The message as it is stored now, which is what the people who look at the room are shown.
  stored = try Rooms.find_message(db, room.id, message.id)
  if stored.none?
    return ok(Answer.NotFound)
  end

  edited = Rooms.clean(stored.unwrap!)
  return ok(Answer.Edited(room, edited, JSON.from(message_json(origin, edited, BOT_ROLE))))
end

def remove_answer(conn: Bond.Conn, db: Db.Connection, bot: Bots.Bot, room: Rooms.Room) -> Result[Answer]
  located = try own_message(conn, db, bot, room)
  case located
    Located.Missing -> return ok(Answer.NotFound)
    Located.Refused -> return ok(Answer.Forbidden)
    Located.Found(message) -> return removed(db, bot, room, message)
  end
end

def removed(db: Db.Connection, bot: Bots.Bot, room: Rooms.Room, message: Rooms.Stored) -> Result[Answer]
  gone = try Rooms.delete_message(db, room.id, message.id, bot.id)
  if not gone
    return ok(Answer.NotFound)
  end

  return ok(Answer.Removed(room, message.id))
end

# The message that the path names, when it is in the room and the bot wrote it. A bot is never an administrator, so the
# author is the only right it has over a message (`User#can_administer?`). The checks inside `Rooms` look again.
def own_message(conn: Bond.Conn, db: Db.Connection, bot: Bots.Bot, room: Rooms.Room) -> Result[Located]
  id = Bond.param_int(conn, MESSAGE)
  if not id.ok?
    return ok(Located.Missing)
  end

  stored = try Rooms.find_message(db, room.id, id.unwrap!)
  case stored
    none -> return ok(Located.Missing)
    some(one) if one.creator_id != bot.id -> return ok(Located.Refused)
    some(one) -> return ok(Located.Found(one))
  end
end

# A file upload (`curl -F attachment=@file`) is a form that would be posted as the text of the message.
def upload?(conn: Bond.Conn) -> Bool
  type = Bond.request_header(conn, "content-type").unwrap_or("")
  return type.downcase.start_with?(UPLOAD_TYPE)
end

def message_json(origin: String, message: Rooms.Message, role: String) -> MessageJson
  return MessageJson(
    id: message.id,
    created_at: message.created_at,
    body: Body(plain_text: HtmlSanitizer.plain_text_of_clean(message.body), html: message.body),
    creator: Creator(id: message.creator_id, name: message.author, role: role),
    room: RoomRef(id: message.room_id),
    url: message_url(origin, message.room_id, message.id),
  )
end

def message_url(origin: String, room_id: Int, message_id: Int) -> String
  return "#{origin}#{Routes.room_message_path(room_id, message_id)}"
end

def announced(conn: Bond.Conn, cable: CableWeb.Cable, answer: Answer) -> Bond.Conn
  case answer
    Answer.Created(room, message, _) -> CableWeb.message_created(cable, room, message)
    Answer.Edited(room, message, _) -> CableWeb.message_edited(cable, room, message)
    Answer.Removed(room, message_id) -> CableWeb.message_removed(cable, room.id, message_id)
    _ -> return answered(conn, answer)
  end

  return answered(conn, answer)
end

def answered(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  return Bond.header(reply(conn, answer), "cache-control", "no-store")
end

def reply(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Listed(messages, total, link) ->
      page = Bond.header(Bond.json(conn, 200, messages), "x-total-count", total.to_s)
      if link == ""
        return page
      end

      return Bond.header(page, "link", "<#{link}>; rel=\"next\"")
    Answer.Created(_, _, location) -> return Bond.header(Bond.status(conn, 201), "location", location)
    Answer.Edited(_, _, message) -> return Bond.json(conn, 200, message)
    Answer.Removed(_, _) -> return Bond.status(conn, 204)
    Answer.Refused(problem) -> return Bond.text(conn, 422, problem)
    Answer.Unsupported -> return Bond.text(conn, 415, UPLOAD_REFUSED)
    Answer.NotFound -> return Bond.text(conn, 404, Routes.MISSING)
    Answer.Forbidden -> return Bond.text(conn, 403, "Forbidden")
  end
end

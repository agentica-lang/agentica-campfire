## The web side of rooms and messages: the forms of a new room (open, closed or direct), a room page, the settings of
## a closed room and the post of a message. Each handler takes one connection of the pool and does everything on it.
## The person is the one that the sign-in filter of `AuthWeb` looked up and kept (`AuthWeb.assigned_user`); a request
## that somehow has none sends the visitor to sign in.
##
## A room that the person is not in is answered 404 with the same body as a room that was never made, before anything
## about the room (or the form posted to it) is looked at, so no answer tells that a room exists. The settings are
## only for an open or a closed room: for a direct room the person is in, they are the same 404. Only the maker of a room
## and an account administrator may change it, and another member is answered 403. The same two people may delete
## a room of any kind, and another member is answered 403 there too. A message is edited and deleted by its author and by
## an account administrator: after the membership check (404) and a message that is not in the room (404), anybody else
## is answered 403, before the form is read.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Cache from "std/cache"
import Cookie from "std/cookie"
import Accounts from "../campfire/accounts"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import CableWeb from "cable"
import Database from "../campfire/repo/database"
import HtmlSanitizer from "../campfire/html_sanitizer"
import MessageCache from "message_cache"
import PageCache from "page_cache"
import RoomDeletion from "room_deletion"
import Rooms from "../campfire/rooms"
import Routes from "routes"
import Views from "views"

# The field names of the form of a message, as Rails nests them (`params.require(:message)`).
MESSAGE_BODY = "message[body]"
MESSAGE_CLIENT_ID = "message[client_message_id]"

# What a post that asks for a Turbo Stream sends in `Accept`, and what the answer is typed.
TURBO_STREAM_TYPE = "text/vnd.turbo-stream.html"

# The cookie that remembers the room that the person was in last (`cookies.permanent[:last_room]` of Rails), and how
# long it lives: 20 years, as Rails' `permanent` is.
LAST_ROOM_COOKIE = "last_room"
LAST_ROOM_SECONDS = 20 * 365 * 24 * 60 * 60

# What a save of a level that the room does not offer is told.
INVOLVEMENT_REFUSED = "That is not a choice for this room"

# The most digits of a `since` that is read as it is; one with more is `SINCE_FAR`, a time that no message is after.
SINCE_DIGITS = 15
SINCE_FAR = 1_000_000_000_000_000

# Bytes of randomness in the `client_message_id` of a form, which is that many bytes in hex.
CLIENT_ID_BYTES = 16

# What a handler makes of its request, decided while its connection is open and answered after it is closed.
enum Answer
  Page(Int, String)
  Cached(PageCache.Page)
  Fragment(String)
  Made(Int, Int, Bool, List[Int])
  Posted(Rooms.Room, Rooms.Message, Bool)
  Edited(Rooms.Room, Rooms.Message)
  Removed(Rooms.Room, Int, Bool)
  TurboStream(String)
  NoContent
  Redirect(String)
  NotFound
  NotAllowed(String)
  Forbidden
  Deleted(Rooms.Room, List[Int])
  SignedOut
end

# Where a request for a message of a room ends up, once the room and the message are looked up for the person.
enum Located
  Missing
  Refused
  Found(Rooms.Room, Rooms.Message)
end

## Adds the routes of the rooms to `app`. They are not in `AuthWeb.PUBLIC_PATHS`, so they need a sign-in. `cable` is
## where a new message and a room that is made or renamed are broadcast, and whose stream of a room the room page
## names. `cache` keeps the markup of the messages that a room page and the older messages write (`MessageCache`),
## `none` for no cache, and `pages` keeps those two pages whole (`PageCache`), `none` for no cache. `secure` makes the
## cookie of the last room `Secure`, as `CAMPFIRE_SECURE_COOKIES` does the session cookie.
export def add(
  app: Bond.App,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  pages: Optional[PageCache.Pages],
  secure: Bool,
) -> Bond.App
  return (
    app
    |> Bond.get(Routes.ROOM_NEW) do |conn| show_new_room(conn, pool) end
    |> Bond.post(Routes.ROOMS) do |conn| create_room(conn, pool, cable) end
    |> Bond.get(Routes.ROOM) do |conn| show_room(conn, pool, cable, cache, pages, secure) end
    |> Bond.get(Routes.ROOM_MESSAGES) do |conn| older_messages(conn, pool, cache, pages) end
    |> Bond.get(Routes.ROOM_REFRESH) do |conn| show_refresh(conn, pool, cache) end
    |> Bond.get(Routes.ROOM_AT) do |conn| show_at(conn, pool, cable, cache, secure) end
    |> Bond.post(Routes.ROOM_MESSAGES) do |conn| create_message(conn, pool, cable, cache) end
    |> Bond.get(Routes.CLOSED_ROOM_NEW) do |conn| show_new_closed_room(conn, pool) end
    |> Bond.post(Routes.CLOSED_ROOMS) do |conn| create_closed_room(conn, pool, cable) end
    |> Bond.get(Routes.DIRECT_ROOM_NEW) do |conn| show_new_direct_room(conn, pool) end
    |> Bond.post(Routes.DIRECT_ROOMS) do |conn| create_direct_room(conn, pool, cable) end
    |> Bond.get(Routes.ROOM_SETTINGS) do |conn| show_settings(conn, pool) end
    |> Bond.post(Routes.ROOM_SETTINGS) do |conn| save_settings(conn, pool, cable) end
    |> Bond.get(Routes.ROOM_INVOLVEMENT) do |conn| show_involvement(conn, pool) end
    |> Bond.post(Routes.ROOM_INVOLVEMENT) do |conn| post_involvement(conn, pool) end
    |> Bond.put(Routes.ROOM_INVOLVEMENT) do |conn| save_involvement(conn, pool) end
    |> Bond.post(Routes.ROOM) do |conn| post_room(conn, pool, cable) end
    |> Bond.delete(Routes.ROOM) do |conn| delete_room(conn, pool, cable) end
    |> Bond.get(Routes.ROOM_MESSAGE_EDIT) do |conn| edit_message(conn, pool) end
    |> Bond.post(Routes.ROOM_MESSAGE) do |conn| post_message(conn, pool, cable) end
    |> Bond.patch(Routes.ROOM_MESSAGE) do |conn| update_message(conn, pool, cable) end
    |> Bond.delete(Routes.ROOM_MESSAGE) do |conn| delete_message(conn, pool, cable) end
  )
end

## The home page of the person: it sends them to the room they were in last, or the oldest one they are in (`Rooms.
## last_visited`), and for a person in no room it is the welcome page, their sidebar and nothing else.
export def home(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  wanted = last_room_cookie(conn)
  answer = try Database.with_connection(pool) do |db| home_answer(conn, db, wanted) end
  return ok(respond(conn, answer))
end

## The column at the side of a page for the person: their rooms that are not hidden and the ways to make one.
export def sidebar_of(db: Db.Connection, person: Auth.User) -> Result[String]
  return sidebar_without(db, person, -1)
end

## The sidebar with the room that the page shows left unmarked: it is read by being looked at, and the page cannot wait
## for the script to say so.
export def sidebar_without(db: Db.Connection, person: Auth.User, open_room: Int) -> Result[String]
  rooms = try Rooms.visible(db, person.id)
  unread = try Rooms.unread_ids(db, person.id)
  can_create = try may_create_rooms?(db, person)
  return ok(Views.sidebar(person.name, rooms, can_create, unread.select do |id| id != open_room end))
end

## `?before=ID` or `?after=ID`, the message that the page shows the ones before (or after). A value that is not a number
## is a 400. The messages API of the bots reads its cursors the same way.
export def cursor(conn: Bond.Conn, name: String) -> Result[Optional[Int]]
  values = try Bond.query_all(conn, name)
  if values.empty?
    return ok(none)
  end

  parsed = values[0].to_i
  if not parsed.ok?
    return Bond.bad_request("#{name} must be a whole number")
  end

  return ok(some(parsed.unwrap!))
end

# Whether the person may make an open or a closed room: an administrator always, anybody else unless the account
# restricts it to administrators (`ensure_permission_to_create_rooms` of Rails). A direct message is never restricted.
def may_create_rooms?(db: Db.Connection, person: Auth.User) -> Result[Bool]
  if person.role == Rooms.ADMINISTRATOR_ROLE_NAME
    return ok(true)
  end

  restricted = try Accounts.room_creation_restricted?(db)
  return ok(not restricted)
end

def home_answer(conn: Bond.Conn, db: Db.Connection, wanted: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return home_of(db, person, wanted)
  end
end

def home_of(db: Db.Connection, person: Auth.User, wanted: Optional[Int]) -> Result[Answer]
  room = try Rooms.last_visited(db, person.id, wanted)
  case room
    some(found) -> return ok(Answer.Redirect(Routes.room_path(found.id)))
    none -> return ok(Answer.Page(200, Views.home(try sidebar_of(db, person))))
  end
end

# The room in the cookie, `none` for no cookie and for one that is not a whole number (a client made it up).
def last_room_cookie(conn: Bond.Conn) -> Optional[Int]
  sent = Bond.cookie(conn, LAST_ROOM_COOKIE)
  if not sent.ok?
    return none
  end

  parsed = sent.unwrap!.to_i
  if parsed.ok?
    return some(parsed.unwrap!)
  end

  return none
end

# The answer, and for a room page that was served (a 200 or a 304) the cookie that makes it the person's last room, as
# `remember_last_room_visited` does for `rooms#show` only. The cookie is written when it is not that room already, so a
# person who stays in a room is not sent it again with every page. The room is the person's: a page is only served to a
# member. The cookie is `Secure` when the session cookie is.
def respond_visit(conn: Bond.Conn, id: Optional[Int], answer: Answer, secure: Bool) -> Bond.Conn
  reply = respond(conn, answer)
  served = false
  case answer
    Answer.Cached(_) -> served = true
    Answer.Page(status, _) -> served = status == 200
    _ -> served = false
  end

  if not served or id.none? or last_room_cookie(conn) == id
    return reply
  end

  made = Cookie.Cookie(
    name: LAST_ROOM_COOKIE,
    value: "#{id.unwrap!}",
    path: "/",
    max_age: LAST_ROOM_SECONDS,
    secure: secure,
    http_only: true,
    same_site: "Lax",
  )

  return Bond.set_cookie_with(reply, made).unwrap_or(reply)
end

def show_new_room(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| new_room_answer(conn, db) end
  return ok(respond(conn, answer))
end

def new_room_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) if not (try may_create_rooms?(db, person)) -> return ok(Answer.Forbidden)
    some(person) -> return ok(Answer.Page(200, Views.new_room(try sidebar_of(db, person), "", "")))
  end
end

def create_room(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| create_room_answer(conn, db) end
  return ok(announced(conn, cable, answer))
end

# The right to make a room is checked before the form is read, as the filter runs before the action in Rails.
def create_room_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) if not (try may_create_rooms?(db, person)) -> return ok(Answer.Forbidden)
    some(person) -> return made_room(db, person, (try Bond.form(conn, "name")).strip)
  end
end

def made_room(db: Db.Connection, person: Auth.User, name: String) -> Result[Answer]
  problem = Rooms.name_problem(name)
  if problem != ""
    return ok(Answer.Page(422, Views.new_room(try sidebar_of(db, person), name, problem)))
  end

  room_id = try Rooms.create_open(db, person.id, name)
  return ok(Answer.Made(room_id, person.id, false, []))
end

def show_new_closed_room(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| new_closed_room_answer(conn, db) end
  return ok(respond(conn, answer))
end

def new_closed_room_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) if not (try may_create_rooms?(db, person)) -> return ok(Answer.Forbidden)
    some(person) -> return ok(Answer.Page(200, try closed_room_form(db, person, "", [], "")))
  end
end

def create_closed_room(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| create_closed_answer(conn, db) end
  return ok(announced(conn, cable, answer))
end

def create_closed_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) if not (try may_create_rooms?(db, person)) -> return ok(Answer.Forbidden)
    some(person) -> return created_closed(conn, db, person)
  end
end

def created_closed(conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Answer]
  name = (try Bond.form(conn, "name")).strip
  ids = try ids_of(conn, "member")
  return made_closed_room(db, person, name, ids)
end

def made_closed_room(db: Db.Connection, person: Auth.User, name: String, ids: List[Int]) -> Result[Answer]
  people = try Rooms.people(db, person.id)
  chosen = chosen_of(people, ids)
  problem = Rooms.name_problem(name)
  if problem != ""
    return ok(Answer.Page(422, try closed_room_form(db, person, name, chosen, problem)))
  end

  room_id = try Rooms.create_closed(db, person.id, name, chosen)
  return ok(Answer.Made(room_id, person.id, false, []))
end

def closed_room_form(
  db: Db.Connection,
  person: Auth.User,
  name: String,
  chosen: List[Int],
  message: String,
) -> Result[String]
  people = try Rooms.people(db, person.id)
  return ok(Views.new_closed_room(try sidebar_of(db, person), name, people, chosen, message))
end

def show_new_direct_room(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| new_direct_room_answer(conn, db) end
  return ok(respond(conn, answer))
end

def new_direct_room_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return ok(Answer.Page(200, try direct_room_form(db, person, [], "")))
  end
end

def create_direct_room(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  ids = try ids_of(conn, "member")
  answer = try Database.with_connection(pool) do |db| create_direct_answer(conn, db, ids) end
  return ok(announced(conn, cable, answer))
end

def create_direct_answer(conn: Bond.Conn, db: Db.Connection, ids: List[Int]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return started_direct_room(db, person, ids)
  end
end

# The same people again open the room that exists (`Rooms.open_direct`), so this redirects either way.
def started_direct_room(db: Db.Connection, person: Auth.User, ids: List[Int]) -> Result[Answer]
  people = try Rooms.people(db, person.id)
  chosen = chosen_of(people, ids)
  problem = Rooms.people_problem(chosen)
  if problem != ""
    return ok(Answer.Page(422, try direct_room_form(db, person, chosen, problem)))
  end

  room_id = try Rooms.open_direct(db, person.id, chosen)
  case room_id
    none -> return ok(Answer.Page(422, try direct_room_form(db, person, [], Rooms.people_problem([]))))
    some(found) -> return ok(Answer.Made(found, person.id, false, []))
  end
end

def direct_room_form(db: Db.Connection, person: Auth.User, chosen: List[Int], message: String) -> Result[String]
  people = try Rooms.people(db, person.id)
  return ok(Views.new_direct_room(try sidebar_of(db, person), people, chosen, message))
end

def show_settings(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  id = room_id(conn)
  wanted = first(try Bond.query_all(conn, "type"))
  answer = try Database.with_connection(pool) do |db| settings_answer(conn, db, id, wanted) end
  return ok(respond(conn, answer))
end

def settings_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int], wanted: String) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return shown_settings(db, person, id, wanted)
  end
end

def shown_settings(db: Db.Connection, person: Auth.User, id: Optional[Int], wanted: String) -> Result[Answer]
  room = try settings_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) if not Rooms.editable?(found, person.id, person.role) -> return ok(Answer.Forbidden)
    some(found) -> return ok(Answer.Page(200, try first_settings(db, person, found, kind_of(found, wanted))))
  end
end

def save_settings(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  id = room_id(conn)
  answer = try Database.with_connection(pool) do |db| save_settings_answer(conn, db, id) end
  return ok(announced(conn, cable, answer))
end

def save_settings_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return saved_settings(conn, db, person, id)
  end
end

# The form is read only after the membership check, so that a 400 for a missing field does not tell a person who is not
# in a room that it exists. A member who may not change the room (not its maker, not an administrator) is told 403:
# they are in the room, so that tells them nothing new.
def saved_settings(conn: Bond.Conn, db: Db.Connection, person: Auth.User, id: Optional[Int]) -> Result[Answer]
  room = try settings_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) if not Rooms.editable?(found, person.id, person.role) -> return ok(Answer.Forbidden)
    some(found) -> return form_settings(conn, db, person, found)
  end
end

def form_settings(conn: Bond.Conn, db: Db.Connection, person: Auth.User, room: Rooms.Room) -> Result[Answer]
  name = (try Bond.form(conn, "name")).strip
  ids = try ids_of(conn, "member")
  was = try ids_of(conn, "was")
  kinds = try Bond.form_all(conn, "type")
  return change_settings(db, person, room, kind_of(room, first(kinds)), name, ids, was)
end

# What the room is to be after the form: the kind that it names (`type`), or what the room is now for no kind or a kind
# that is none of the two, so a form of the first version of the settings (no `type`) keeps its meaning.
def kind_of(room: Rooms.Room, wanted: String) -> String
  if wanted == Routes.SETTINGS_OPEN or wanted == Routes.SETTINGS_CLOSED
    return wanted
  end

  if Rooms.open?(room)
    return Routes.SETTINGS_OPEN
  end

  return Routes.SETTINGS_CLOSED
end

def first(values: List[String]) -> String
  if values.empty?
    return ""
  end

  return values[0]
end

def change_settings(
  db: Db.Connection,
  person: Auth.User,
  room: Rooms.Room,
  kind: String,
  name: String,
  ids: List[Int],
  was: List[Int],
) -> Result[Answer]
  people = try Rooms.people(db, person.id)
  chosen = chosen_of(people, ids)
  problem = Rooms.name_problem(name)
  if problem != ""
    page = try settings_form(db, person, room, kind, name, chosen, chosen_of(people, was), problem)
    return ok(Answer.Page(422, page))
  end

  before = try Rooms.member_ids(db, room.id)
  changed = try Rooms.update_room(db, room.id, person.id, name, kind == Routes.SETTINGS_OPEN, chosen, was)
  # The check before the form said they may; a refusal now is a change that happened meanwhile (they were taken out,
  # or lost the role), so they are told what a person who is not in the room is.
  if not changed
    return ok(Answer.NotFound)
  end

  # The people whose membership the update really deleted lose the stream of the room's messages, which was
  # checked when
  # they subscribed. They are read from the database, not from the form: `was` is the client's.
  after = try Rooms.member_ids(db, room.id)
  removed = before.select do |id| not after.include?(id) end
  return ok(Answer.Made(room.id, person.id, true, removed))
end

# The form of the `kind` as it is first drawn: the people in the room are checked, and are the ones that it remembers
# as in it (an open room drawn as closed has everyone checked).
def first_settings(db: Db.Connection, person: Auth.User, room: Rooms.Room, kind: String) -> Result[String]
  members = try Rooms.member_ids(db, room.id)
  return settings_form(db, person, room, kind, room.name, members, members, "")
end

# A refused form comes back with what was typed and checked, and with the `was` that it had, so that fixing the name
# still takes out the people that it unchecked.
def settings_form(
  db: Db.Connection,
  person: Auth.User,
  room: Rooms.Room,
  kind: String,
  name: String,
  chosen: List[Int],
  was: List[Int],
  message: String,
) -> Result[String]
  people = try Rooms.people(db, person.id)
  return ok(Views.room_settings(try sidebar_of(db, person), room, kind, name, people, chosen, was, message))
end

def show_involvement(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  id = room_id(conn)
  answer = try Database.with_connection(pool) do |db| involvement_answer(conn, db, id, false) end
  return ok(respond(conn, answer))
end

# The form of Rails posts to the involvement with `_method=put` (in any case, as Rails reads it); any other post is a
# 405 that says which methods the path takes, whatever the room.
def post_involvement(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  if method != Routes.METHOD_PUT
    return ok(respond(conn, Answer.NotAllowed(Routes.ROOM_INVOLVEMENT_ALLOW)))
  end

  return save_involvement(conn, pool)
end

def save_involvement(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  id = room_id(conn)
  answer = try Database.with_connection(pool) do |db| involvement_answer(conn, db, id, true) end
  return ok(respond(conn, answer))
end

def involvement_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int], save: Bool) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return involvement_of(conn, db, person, id, save)
  end
end

# Membership first, as everywhere, so that the field is read (and refused with a 400) only for a person who is in the
# room. Any kind of room has the page, since the person is in it; what differs is the levels it offers.
def involvement_of(
  conn: Bond.Conn,
  db: Db.Connection,
  person: Auth.User,
  id: Optional[Int],
  save: Bool,
) -> Result[Answer]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) if save -> return saved_involvement(conn, db, person, found)
    some(found) -> return ok(Answer.Page(200, try involvement_page(db, person, found, "")))
  end
end

# A level that the room does not offer (any for a direct room, or one made up) is a 422 with the page again and the
# level that the person has, so nothing is changed. A level that it offers but that was not saved means the membership
# went between the check and the update, which is a person who is not in the room: a 404. A save ends at the page, as
# Rails' `redirect_to` does.
def saved_involvement(conn: Bond.Conn, db: Db.Connection, person: Auth.User, room: Rooms.Room) -> Result[Answer]
  level = try Bond.form(conn, "involvement")
  changed = try Rooms.set_involvement(db, person.id, room, level)
  if not changed and Rooms.involvement_levels(room).include?(level)
    return ok(Answer.NotFound)
  end

  if not changed
    page = try involvement_page(db, person, room, INVOLVEMENT_REFUSED)
    return ok(Answer.Page(422, page))
  end

  return ok(Answer.Redirect(Routes.room_involvement_path(room.id)))
end

def involvement_page(db: Db.Connection, person: Auth.User, room: Rooms.Room, message: String) -> Result[String]
  level = try Rooms.involvement(db, person.id, room.id)
  hidden = Rooms.hidden?(level.unwrap_or(""))
  return ok(Views.involvement(try sidebar_of(db, person), room, Rooms.involvement_levels(room), hidden, message))
end

# The form of Rails posts to the room with `_method=delete` (in any case, as Rails reads it); any other post is what a
# `POST` to the path was before the form existed (the router's own answer), a 405 that says which methods the path
# takes, whatever the room.
def post_room(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  if method != Routes.METHOD_DELETE
    return ok(respond(conn, Answer.NotAllowed(Routes.ROOM_ALLOW)))
  end

  return delete_room(conn, pool, cable)
end

# The task that deletes the messages starts after the connection is given back, from the task of the request, and so
# does the news of the deletion to the people who were in the room.
def delete_room(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  id = room_id(conn)
  answer = try Database.with_connection(pool) do |db| delete_answer(conn, db, id) end
  case answer
    Answer.Deleted(deleted, _) -> RoomDeletion.start(pool, deleted.id)
    _ -> return ok(respond(conn, answer))
  end

  return ok(announced(conn, cable, answer))
end

def delete_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return deleted_room(db, person, id)
  end
end

# Membership first, as everywhere: a person who is not in the room is told what a room that does not exist is told.
# `destroy_later` checks the right again inside its transaction; a refusal there is a change that happened meanwhile.
def deleted_room(db: Db.Connection, person: Auth.User, id: Optional[Int]) -> Result[Answer]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) if not Rooms.administrable?(found, person.id, person.role) -> return ok(Answer.Forbidden)
    some(found) -> return taken_away(db, person, found)
  end
end

def taken_away(db: Db.Connection, person: Auth.User, room: Rooms.Room) -> Result[Answer]
  # Read before `destroy_later` takes every membership away: they are the people who are told.
  members = try Rooms.member_ids(db, room.id)
  done = try Rooms.destroy_later(db, room.id, person.id)
  if not done
    return ok(Answer.NotFound)
  end

  return ok(Answer.Deleted(room, members))
end

def edit_message(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  id = room_id(conn)
  message_id = message_id(conn)
  answer = try Database.with_connection(pool) do |db| edit_answer(conn, db, id, message_id) end
  return ok(respond(conn, answer))
end

def edit_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int], message_id: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return edit_form_answer(db, person, id, message_id)
  end
end

def edit_form_answer(
  db: Db.Connection,
  person: Auth.User,
  id: Optional[Int],
  message_id: Optional[Int],
) -> Result[Answer]
  located = try locate(db, person, id, message_id)
  case located
    Located.Missing -> return ok(Answer.NotFound)
    Located.Refused -> return ok(Answer.Forbidden)
    Located.Found(room, message) -> return ok(Answer.Page(200, try edit_page(db, person, room, message, none, "")))
  end
end

# `typed` is what was sent when a refusal shows the page again, `none` for the text that the message has.
def edit_page(
  db: Db.Connection,
  person: Auth.User,
  room: Rooms.Room,
  message: Rooms.Message,
  typed: Optional[String],
  note: String,
) -> Result[String]
  text = typed.unwrap_or(HtmlSanitizer.text_of_clean(message.body))
  return ok(Views.edit_message(try sidebar_of(db, person), room, message, text, note))
end

# The form of Rails posts to the message with `_method` `patch` to save it and `delete` to delete it (in any case, as
# Rails reads it); any other post is a 405 that says which methods the path takes, whatever the message.
def post_message(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  if method == Routes.METHOD_PATCH
    return update_message(conn, pool, cable)
  end

  if method == Routes.METHOD_DELETE
    return delete_message(conn, pool, cable)
  end

  return ok(respond(conn, Answer.NotAllowed(Routes.ROOM_MESSAGE_ALLOW)))
end

def update_message(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  id = room_id(conn)
  message_id = message_id(conn)
  answer = try Database.with_connection(pool) do |db| update_answer(conn, db, id, message_id) end
  return ok(announced(conn, cable, answer))
end

def update_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int], message_id: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return updated_message(conn, db, person, id, message_id)
  end
end

# The body is read only after the right is checked, as everywhere, so that a 400 for a missing field does not tell a
# person who may not see the message that it exists.
def updated_message(
  conn: Bond.Conn,
  db: Db.Connection,
  person: Auth.User,
  id: Optional[Int],
  message_id: Optional[Int],
) -> Result[Answer]
  located = try locate(db, person, id, message_id)
  case located
    Located.Missing -> return ok(Answer.NotFound)
    Located.Refused -> return ok(Answer.Forbidden)
    Located.Found(room, message) -> return save_message(conn, db, person, room, message)
  end
end

def save_message(
  conn: Bond.Conn,
  db: Db.Connection,
  person: Auth.User,
  room: Rooms.Room,
  message: Rooms.Message,
) -> Result[Answer]
  body = (try Bond.form(conn, MESSAGE_BODY)).strip
  problem = Rooms.body_problem(body)
  if problem != ""
    page = try edit_page(db, person, room, message, some(body), problem)
    return ok(Answer.Page(422, page))
  end

  saved = try Rooms.update_message(db, room.id, message.id, person.id, HtmlSanitizer.from_text(body))
  # A refusal now is a change that happened meanwhile (they were taken out of the room, or lost the role).
  if not saved
    return ok(Answer.NotFound)
  end

  # The message as it is stored now, for the people who are looking at the room.
  stored = try Rooms.find_message(db, room.id, message.id)
  if stored.none?
    return ok(Answer.Redirect(Routes.room_path(room.id)))
  end

  return ok(Answer.Edited(room, Rooms.clean(stored.unwrap!)))
end

def delete_message(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  id = room_id(conn)
  message_id = message_id(conn)
  stream = wants_stream?(conn)
  answer = try Database.with_connection(pool) do |db| delete_message_answer(conn, db, id, message_id, stream) end
  return ok(announced(conn, cable, answer))
end

def delete_message_answer(
  conn: Bond.Conn,
  db: Db.Connection,
  id: Optional[Int],
  message_id: Optional[Int],
  stream: Bool,
) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return deleted_message(db, person, id, message_id, stream)
  end
end

# A browser with the scripts of Turbo asks for a Turbo Stream that takes the message off the page; a plain form
# gets the
# room page.
def deleted_message(
  db: Db.Connection,
  person: Auth.User,
  id: Optional[Int],
  message_id: Optional[Int],
  stream: Bool,
) -> Result[Answer]
  located = try locate(db, person, id, message_id)
  case located
    Located.Missing -> return ok(Answer.NotFound)
    Located.Refused -> return ok(Answer.Forbidden)
    Located.Found(room, message) -> return gone_message(db, person, room, message, stream)
  end
end

def gone_message(
  db: Db.Connection,
  person: Auth.User,
  room: Rooms.Room,
  message: Rooms.Message,
  stream: Bool,
) -> Result[Answer]
  gone = try Rooms.delete_message(db, room.id, message.id, person.id)
  if not gone
    return ok(Answer.NotFound)
  end

  return ok(Answer.Removed(room, message.id, stream))
end

# The message that the path names, for a person who is in the room: `Missing` for a room that is not theirs and for a
# message that is not in it (the same answer, so neither tells that the other exists), `Refused` for a message
# that they
# may not change.
def locate(db: Db.Connection, person: Auth.User, id: Optional[Int], message_id: Optional[Int]) -> Result[Located]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Located.Missing)
    some(found) -> return located_message(db, person, found, message_id)
  end
end

def located_message(
  db: Db.Connection,
  person: Auth.User,
  room: Rooms.Room,
  message_id: Optional[Int],
) -> Result[Located]
  case message_id
    none -> return ok(Located.Missing)
    some(wanted) ->
      stored = try Rooms.find_message(db, room.id, wanted)
      case stored
        none -> return ok(Located.Missing)
        some(one) if not Rooms.changeable?(one.creator_id, person.id, person.role) -> return ok(Located.Refused)
        some(one) -> return ok(Located.Found(room, Rooms.clean(one)))
      end
  end
end

def show_room(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  pages: Optional[PageCache.Pages],
  secure: Bool,
) -> Result[Bond.Conn]
  before = try cursor(conn, "before")
  id = room_id(conn)
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(respond(conn, Answer.SignedOut))
    some(person) -> return shown_room(conn, pool, cable, cache, pages, secure, person, id, before)
  end
end

# The version of the database is read before the page is made (`PageCache.spot`), so a page that is kept is never older
# than its key; on a hit the room is not looked up at all (see the top of `page_cache.agc`).
def shown_room(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  pages: Optional[PageCache.Pages],
  secure: Bool,
  person: Auth.User,
  id: Optional[Int],
  before: Optional[Int],
) -> Result[Bond.Conn]
  spot = PageCache.spot(pages, PageCache.seen(conn), PageCache.ROOM, person, id, before)
  kept = PageCache.lookup(spot)
  case kept
    some(page) -> return ok(respond_visit(conn, id, Answer.Cached(page), secure))
    none -> return made_room_page(conn, pool, cable, cache, spot, secure, person, id, before)
  end
end

def made_room_page(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  spot: Optional[PageCache.Spot],
  secure: Bool,
  person: Auth.User,
  id: Optional[Int],
  before: Optional[Int],
) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| room_answer(db, cable, cache, person, id, before) end
  return ok(respond_visit(conn, id, kept(spot, answer), secure))
end

def room_answer(
  db: Db.Connection,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  person: Auth.User,
  id: Optional[Int],
  before: Optional[Int],
) -> Result[Answer]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) ->
      page = try room_page(db, cable, cache, person, found, before, composer("", ""))
      return ok(Answer.Page(200, page))
  end
end

# A page that was made (a 200) is kept at `spot` and answered with its tag; any other answer is as it is.
def kept(spot: Optional[PageCache.Spot], answer: Answer) -> Answer
  case answer
    Answer.Page(status, html) if status == 200 -> return Answer.Cached(PageCache.keep(spot, html))
    Answer.Fragment(html) -> return Answer.Cached(PageCache.keep(spot, html))
    _ -> return answer
  end
end

# The messages that come before `?before=ID` (the newest 40 without it) or, with `?after=ID` and no `before`, the 40
# that come after it (Rails reads `before` first too), as the fragment that the script of the page puts in the list:
# no layout, no sidebar. Rails answers 204 when there is nothing to add, and so does this.
def older_messages(
  conn: Bond.Conn,
  pool: Database.Pool,
  cache: Optional[Cache.Store],
  pages: Optional[PageCache.Pages],
) -> Result[Bond.Conn]
  before = try cursor(conn, "before")
  after = try cursor(conn, "after")
  id = room_id(conn)
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(respond(conn, Answer.SignedOut))
    some(person) -> return older_page(conn, pool, cache, pages, person, id, before, after)
  end
end

def older_page(
  conn: Bond.Conn,
  pool: Database.Pool,
  cache: Optional[Cache.Store],
  pages: Optional[PageCache.Pages],
  person: Auth.User,
  id: Optional[Int],
  before: Optional[Int],
  after: Optional[Int],
) -> Result[Bond.Conn]
  # The two cursors are kept apart, so `?before=7` and `?after=7` are two pages.
  spot: Optional[PageCache.Spot] = none
  if before.none? and after.some?
    spot = PageCache.spot(pages, PageCache.seen(conn), PageCache.AFTER, person, id, after)
  else
    spot = PageCache.spot(pages, PageCache.seen(conn), PageCache.MESSAGES, person, id, before)
  end

  found = PageCache.lookup(spot)
  case found
    some(page) -> return ok(respond(conn, Answer.Cached(page)))
    none -> return made_older_page(conn, pool, cache, spot, person, id, before, after)
  end
end

def made_older_page(
  conn: Bond.Conn,
  pool: Database.Pool,
  cache: Optional[Cache.Store],
  spot: Optional[PageCache.Spot],
  person: Auth.User,
  id: Optional[Int],
  before: Optional[Int],
  after: Optional[Int],
) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| older_fragment(db, cache, person, id, before, after) end
  return ok(respond(conn, kept(spot, answer)))
end

def older_fragment(
  db: Db.Connection,
  cache: Optional[Cache.Store],
  person: Auth.User,
  id: Optional[Int],
  before: Optional[Int],
  after: Optional[Int],
) -> Result[Answer]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) -> return ok(fragment_of(cache, person, try older_messages_of(db, found, before, after)))
  end
end

def older_messages_of(
  db: Db.Connection,
  room: Rooms.Room,
  before: Optional[Int],
  after: Optional[Int],
) -> Result[List[Rooms.Stored]]
  case after
    some(anchor) if before.none? -> return Rooms.page_after(db, room.id, anchor)
    _ -> return ok((try Rooms.page(db, room.id, before)).messages)
  end
end

def fragment_of(cache: Optional[Cache.Store], person: Auth.User, messages: List[Rooms.Stored]) -> Answer
  if messages.empty?
    return Answer.NoContent
  end

  return Answer.Fragment(MessageCache.list(cache, messages, person.id, person.role))
end

# `/rooms/ID/@MESSAGE`: the room page around a message (Rails routes `@:message_id` to `rooms#show`, and `page_around`
# gives 40 before it, it, and 40 after). A message that the room does not have gives the newest page, as in Rails. Bond
# params are whole segments, so the route takes any segment after the room and this handler answers 404 for one that
# is not `@` and a number. The page is not kept (`PageCache`): there is one for every message, and a person could fill
# the cache with them, as with `?before=` on the room page. It is a room page, so it sets the last room.
def show_at(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  secure: Bool,
) -> Result[Bond.Conn]
  id = room_id(conn)
  at = at_message(conn)
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(respond(conn, Answer.SignedOut))
    some(person) ->
      answer = try Database.with_connection(pool) do |db| at_answer(db, cable, cache, person, id, at) end
      return ok(respond_visit(conn, id, answer, secure))
  end
end

def at_answer(
  db: Db.Connection,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  person: Auth.User,
  id: Optional[Int],
  at: Optional[Int],
) -> Result[Answer]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(_) if at.none? -> return ok(Answer.NotFound)
    some(found) -> return ok(Answer.Page(200, try around_page(db, cable, cache, person, found, at.unwrap!)))
  end
end

def around_page(
  db: Db.Connection,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  person: Auth.User,
  room: Rooms.Room,
  message_id: Int,
) -> Result[String]
  around = try Rooms.around(db, room.id, message_id)
  page = Rooms.Page(messages: [], older: none, at_latest: true)
  case around
    some(found) -> page = found
    none -> page = try Rooms.page(db, room.id, none)
  end

  return page_view(db, cable, cache, person, room, page, composer("", ""))
end

# `/rooms/ID/refresh?since=MILLISECONDS`: what a client missed since a time, as Turbo Streams (the live client calls it
# to catch up after a lost connection): the new messages appended to the list, and a replace for each message that
# was edited. Rails reads `since` with `to_i`, so no value, or one that is no number, is the epoch (every message,
# the first 40). It answers Turbo Stream whatever `Accept` says, and an empty body when nothing changed.
def show_refresh(conn: Bond.Conn, pool: Database.Pool, cache: Optional[Cache.Store]) -> Result[Bond.Conn]
  id = room_id(conn)
  since = try since_of(conn)
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(respond(conn, Answer.SignedOut))
    some(person) ->
      answer = try Database.with_connection(pool) do |db| refresh_answer(db, cache, person, id, since) end
      return ok(respond(conn, answer))
  end
end

def refresh_answer(
  db: Db.Connection,
  cache: Optional[Cache.Store],
  person: Auth.User,
  id: Optional[Int],
  since: Int,
) -> Result[Answer]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) -> return refreshed(db, cache, person, found, since)
  end
end

def refreshed(
  db: Db.Connection,
  cache: Optional[Cache.Store],
  person: Auth.User,
  room: Rooms.Room,
  since: Int,
) -> Result[Answer]
  gained = try Rooms.since(db, room.id, since)
  appended = ""
  if not gained.fresh.empty?
    appended = Views.messages_appended(room, MessageCache.list(cache, gained.fresh, person.id, person.role))
  end

  replaced = gained.changed.map do |one|
    Views.message_replaced(one.id, MessageCache.list(cache, [one], person.id, person.role))
  end

  return ok(Answer.TurboStream([appended].concat(replaced).select do |part| not part.empty? end.join("\n")))
end

def create_message(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
) -> Result[Bond.Conn]
  # What a form of this app always has, so a missing or odd value is a request that no page of ours made (a 400),
  # whatever the room: nothing here depends on the room.
  body = (try Bond.form(conn, MESSAGE_BODY)).strip
  sent_id = try client_id(conn)
  id = room_id(conn)
  stream = wants_stream?(conn)
  answer = try Database.with_connection(pool) do |db|
    message_answer(conn, db, cable, cache, id, body, sent_id, stream)
  end

  return ok(announced(conn, cable, answer))
end

# A browser that runs the scripts of the page asks for a Turbo Stream, and gets the message to append; a form that
# was sent without them (`Accept` of a plain browser, or none) gets the redirect to the room page.
def wants_stream?(conn: Bond.Conn) -> Bool
  accept = Bond.request_header(conn, "accept")
  return accept.ok? and accept.unwrap!.include?(TURBO_STREAM_TYPE)
end

def message_answer(
  conn: Bond.Conn,
  db: Db.Connection,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  id: Optional[Int],
  body: String,
  sent_id: String,
  stream: Bool,
) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return posted(db, cable, cache, person, id, body, sent_id, stream)
  end
end

# Membership first: a refusal of the text must not tell a person who is not in a room that it exists.
def posted(
  db: Db.Connection,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  person: Auth.User,
  id: Optional[Int],
  body: String,
  sent_id: String,
  stream: Bool,
) -> Result[Answer]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) -> return post_to(db, cable, cache, person, found, body, sent_id, stream)
  end
end

def post_to(
  db: Db.Connection,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  person: Auth.User,
  room: Rooms.Room,
  body: String,
  sent_id: String,
  stream: Bool,
) -> Result[Answer]
  problem = Rooms.body_problem(body)
  if problem != ""
    page = try room_page(db, cable, cache, person, room, none, composer(problem, body))
    return ok(Answer.Page(422, page))
  end

  # The insert stores nothing for a person who was deactivated since the filter looked them up, nor in a room that was
  # deleted since the membership check (which also took the person out of it): looking the room up again tells which.
  stored = try Rooms.post(db, room.id, person.id, sent_id, HtmlSanitizer.from_text(body))
  case stored
    none -> return ok(try refused_post(db, person, room))
    some(message) -> return ok(Answer.Posted(room, message, stream))
  end
end

def refused_post(db: Db.Connection, person: Auth.User, room: Rooms.Room) -> Result[Answer]
  still = try member_room(db, person, some(room.id))
  case still
    none -> return ok(Answer.NotFound)
    some(_) -> return ok(Answer.SignedOut)
  end
end

# A page of the room with a form that has a new id, so that sending it again after a refusal is a new message.
def room_page(
  db: Db.Connection,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  person: Auth.User,
  room: Rooms.Room,
  before: Optional[Int],
  form: Views.Composer,
) -> Result[String]
  page = try Rooms.page(db, room.id, before)
  return page_view(db, cable, cache, person, room, page, form)
end

def page_view(
  db: Db.Connection,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  person: Auth.User,
  room: Rooms.Room,
  page: Rooms.Page,
  form: Views.Composer,
) -> Result[String]
  thread = MessageCache.list(cache, page.messages, person.id, person.role)
  return ok(
    Views.room(
      try sidebar_without(db, person, room.id),
      room,
      page,
      thread,
      form,
      Rooms.editable?(room, person.id, person.role),
      CableWeb.room_sources(cable, room.id),
      person.id,
    ),
  )
end

# The id of the form is drawn when a page is made, and a page that is kept (`PageCache`) is served to every load of
# the person at that version of the database, so two tabs can post with the same `client_message_id`: nothing may
# drop a message because its id was seen before.
def composer(note: String, draft: String) -> Views.Composer
  return Views.Composer(note: note, draft: draft, message_id: SecureRandom.hex(CLIENT_ID_BYTES))
end

def member_room(db: Db.Connection, person: Auth.User, id: Optional[Int]) -> Result[Optional[Rooms.Room]]
  case id
    none -> return ok(none)
    some(room_id) -> return Rooms.find(db, person.id, room_id)
  end
end

# A room of the person that has settings: a direct room has none, so it is as missing as a room of other people.
def settings_room(db: Db.Connection, person: Auth.User, id: Optional[Int]) -> Result[Optional[Rooms.Room]]
  room = try member_room(db, person, id)
  case room
    some(found) if Rooms.has_settings?(found) -> return ok(room)
    _ -> return ok(none)
  end
end

# The ids that a form posts under `field`, in the order sent: a value that is not a whole number is a 400, since only
# a tool posts one.
def ids_of(conn: Bond.Conn, field: String) -> Result[List[Int]]
  values = try Bond.form_all(conn, field)
  ids: List[Int] = []
  for value in values
    parsed = value.to_i
    if not parsed.ok?
      return Bond.bad_request("#{field} must be a whole number")
    end

    ids = ids.push(parsed.unwrap!)
  end

  return ok(ids)
end

# The ids among `ids` that name one of the `people` that the form offered: the ones that name nobody (an inactive
# person, a number that is no user) are left out, and so is the person who sends the form, who is never in `people`.
def chosen_of(people: List[Rooms.Person], ids: List[Int]) -> List[Int]
  return people.select do |person| ids.include?(person.id) end.map do |person| person.id end
end

# A room id that is not a whole number (or is too big for one) names no room, which is a 404 like any other.
def room_id(conn: Bond.Conn) -> Optional[Int]
  text = Bond.param(conn, "id").unwrap_or("")
  parsed = text.to_i
  if parsed.ok?
    return some(parsed.unwrap!)
  end

  return none
end

# A message id that is not a whole number names no message, which is a 404 like any other.
def message_id(conn: Bond.Conn) -> Optional[Int]
  text = Bond.param(conn, "message_id").unwrap_or("")
  parsed = text.to_i
  if parsed.ok?
    return some(parsed.unwrap!)
  end

  return none
end

# `?since=`, as Ruby's `to_i` reads it: the whitespace, the sign and the digits at the start, and nothing after them
# (`12abc` is 12, `1.5e3` is 1), so a value with no digits is 0. More digits than any time has are as far in the future
# as one can write, which no message is after.
def since_of(conn: Bond.Conn) -> Result[Int]
  values = try Bond.query_all(conn, "since")
  if values.empty?
    return ok(0)
  end

  text = values[0].strip
  negative = text.start_with?("-")
  if negative or text.start_with?("+")
    text = text.slice(1, text.length - 1)
  end

  digits = ""
  for ch in text.split("")
    if not "0123456789".include?(ch)
      break
    end

    digits = digits + ch
  end

  if digits.empty?
    return ok(0)
  end

  if digits.length > SINCE_DIGITS
    return ok(SINCE_FAR)
  end

  value = digits.to_i.unwrap_or(0)
  if negative
    return ok(0 - value)
  end

  return ok(value)
end

# The message of `/rooms/ID/@MESSAGE`: `none` for a segment that is not `@` and a whole number.
def at_message(conn: Bond.Conn) -> Optional[Int]
  text = Bond.param(conn, "segment").unwrap_or("")
  if not text.start_with?(Routes.AT_PREFIX)
    return none
  end

  parsed = text.slice(1, text.length - 1).to_i
  if parsed.ok?
    return some(parsed.unwrap!)
  end

  return none
end

# The id that the form carries for its message, or a new one for a post that has none (a tool, not our page). Too
# long a value is a 400: the column holds anything, so the limit is ours.
def client_id(conn: Bond.Conn) -> Result[String]
  values = try Bond.form_all(conn, MESSAGE_CLIENT_ID)
  if values.empty? or values[0].empty?
    return ok(SecureRandom.hex(CLIENT_ID_BYTES))
  end

  if values[0].length > Rooms.MAX_CLIENT_ID_LENGTH
    return Bond.bad_request("#{MESSAGE_CLIENT_ID} is at most #{Rooms.MAX_CLIENT_ID_LENGTH} characters")
  end

  return ok(values[0])
end

# What the live clients hear of an answer, after its connection is back in the pool (a broadcast may wait for room in
# the hub), and then the answer itself.
def announced(conn: Bond.Conn, cable: CableWeb.Cable, answer: Answer) -> Bond.Conn
  case answer
    Answer.Made(room_id, actor_id, renamed, removed) ->
      CableWeb.members_removed(cable, removed)
      CableWeb.room_changed(cable, room_id, actor_id, renamed)
    Answer.Posted(room, message, _) -> CableWeb.message_created(cable, room, message)
    Answer.Deleted(room, members) -> CableWeb.room_deleted(cable, room, members)
    Answer.Edited(room, message) -> CableWeb.message_edited(cable, room, message)
    Answer.Removed(room, message_id, _) -> CableWeb.message_removed(cable, room.id, message_id)
    _ -> return respond(conn, answer)
  end

  return respond(conn, answer)
end

def respond(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Page(status, html) -> return Bond.html(conn, status, html)
    Answer.Cached(page) -> return PageCache.respond(conn, page)
    Answer.Fragment(html) -> return Bond.html(conn, 200, html)
    Answer.Made(room_id, _, _, _) -> return Bond.redirect(conn, Routes.room_path(room_id))
    Answer.Posted(room, message, stream) if stream ->
      return Bond.header(
        Bond.html(conn, 200, Views.message_stream(room, message, true)),
        "content-type",
        TURBO_STREAM_TYPE + "; charset=utf-8",
      )
    Answer.Posted(room, _, _) -> return Bond.redirect(conn, Routes.room_path(room.id))
    Answer.Edited(room, _) -> return Bond.redirect(conn, Routes.room_path(room.id))
    Answer.Removed(_, message_id, stream) if stream ->
      return Bond.header(
        Bond.html(conn, 200, Views.message_removed(message_id)),
        "content-type",
        TURBO_STREAM_TYPE + "; charset=utf-8",
      )
    Answer.Removed(room, _, _) -> return Bond.redirect(conn, Routes.room_path(room.id))
    Answer.TurboStream(html) ->
      return Bond.header(Bond.html(conn, 200, html), "content-type", TURBO_STREAM_TYPE + "; charset=utf-8")
    Answer.NoContent -> return Bond.status(conn, 204)
    Answer.Redirect(path) -> return Bond.redirect(conn, path)
    Answer.NotFound -> return Bond.text(conn, 404, Routes.MISSING)
    Answer.NotAllowed(allow) -> return Bond.header(Bond.text(conn, 405, "method not allowed"), "allow", allow)
    Answer.Forbidden -> return Bond.text(conn, 403, "Forbidden")
    Answer.Deleted(_, _) -> return Bond.redirect(conn, Routes.HOME)
    Answer.SignedOut -> return Bond.redirect(conn, Routes.SIGN_IN)
  end
end

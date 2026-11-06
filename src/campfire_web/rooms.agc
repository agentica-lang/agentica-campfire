## The web side of rooms and messages: the forms of a new room (open, closed or direct), a room page, the settings of
## a closed room and the post of a message. Each handler takes one connection of the pool and does everything on it.
## The person is the one that the sign-in filter of `AuthWeb` looked up and kept (`AuthWeb.assigned_user`); a request
## that somehow has none sends the visitor to sign in.
##
## A room that the person is not in is answered 404 with the same body as a room that was never made, before anything
## about the room (or the form posted to it) is looked at, so no answer tells that a room exists. The settings are
## only for a closed room: for a room of another kind the person is in, they are the same 404. In a closed room only its
## maker and an account administrator may change it, and another member is answered 403. The same two people may delete
## a room of any kind, and another member is answered 403 there too.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Cache from "std/cache"
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

# Bytes of randomness in the `client_message_id` of a form, which is that many bytes in hex.
CLIENT_ID_BYTES = 16

# What a handler makes of its request, decided while its connection is open and answered after it is closed.
enum Answer
  Page(Int, String)
  Cached(PageCache.Page)
  Fragment(String)
  Made(Int, Int, Bool, List[Int])
  Posted(Rooms.Room, Rooms.Message, Bool)
  NoContent
  Redirect(String)
  NotFound
  NotAllowed(String)
  Forbidden
  Deleted(Int)
  SignedOut
end

## Adds the routes of the rooms to `app`. They are not in `AuthWeb.PUBLIC_PATHS`, so they need a sign-in. `cable` is
## where a new message and a room that is made or renamed are broadcast, and whose stream of a room the room page
## names. `cache` keeps the markup of the messages that a room page and the older messages write (`MessageCache`),
## `none` for no cache, and `pages` keeps those two pages whole (`PageCache`), `none` for no cache.
export def add(
  app: Bond.App,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  pages: Optional[PageCache.Pages],
) -> Bond.App
  return (
    app
    |> Bond.get(Routes.ROOM_NEW) do |conn| show_new_room(conn, pool) end
    |> Bond.post(Routes.ROOMS) do |conn| create_room(conn, pool, cable) end
    |> Bond.get(Routes.ROOM) do |conn| show_room(conn, pool, cable, cache, pages) end
    |> Bond.get(Routes.ROOM_MESSAGES) do |conn| older_messages(conn, pool, cache, pages) end
    |> Bond.post(Routes.ROOM_MESSAGES) do |conn| create_message(conn, pool, cable, cache) end
    |> Bond.get(Routes.CLOSED_ROOM_NEW) do |conn| show_new_closed_room(conn, pool) end
    |> Bond.post(Routes.CLOSED_ROOMS) do |conn| create_closed_room(conn, pool, cable) end
    |> Bond.get(Routes.DIRECT_ROOM_NEW) do |conn| show_new_direct_room(conn, pool) end
    |> Bond.post(Routes.DIRECT_ROOMS) do |conn| create_direct_room(conn, pool, cable) end
    |> Bond.get(Routes.ROOM_SETTINGS) do |conn| show_settings(conn, pool) end
    |> Bond.post(Routes.ROOM_SETTINGS) do |conn| save_settings(conn, pool, cable) end
    |> Bond.post(Routes.ROOM) do |conn| post_room(conn, pool) end
    |> Bond.delete(Routes.ROOM) do |conn| delete_room(conn, pool) end
  )
end

## The home page of the person: their sidebar and nothing else yet.
export def home(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| home_answer(conn, db) end
  return ok(respond(conn, answer))
end

## The column at the side of a page for the person: their rooms that are not hidden and the ways to make one.
export def sidebar_of(db: Db.Connection, person: Auth.User) -> Result[String]
  rooms = try Rooms.visible(db, person.id)
  return ok(Views.sidebar(person.name, rooms))
end

def home_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return ok(Answer.Page(200, Views.home(try sidebar_of(db, person))))
  end
end

def show_new_room(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| new_room_answer(conn, db) end
  return ok(respond(conn, answer))
end

def new_room_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return ok(Answer.Page(200, Views.new_room(try sidebar_of(db, person), "", "")))
  end
end

def create_room(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  name = (try Bond.form(conn, "name")).strip
  answer = try Database.with_connection(pool) do |db| create_room_answer(conn, db, name) end
  return ok(announced(conn, cable, answer))
end

def create_room_answer(conn: Bond.Conn, db: Db.Connection, name: String) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return made_room(db, person, name)
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
    some(person) -> return ok(Answer.Page(200, try closed_room_form(db, person, "", [], "")))
  end
end

def create_closed_room(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  name = (try Bond.form(conn, "name")).strip
  ids = try ids_of(conn, "member")
  answer = try Database.with_connection(pool) do |db| create_closed_answer(conn, db, name, ids) end
  return ok(announced(conn, cable, answer))
end

def create_closed_answer(conn: Bond.Conn, db: Db.Connection, name: String, ids: List[Int]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return made_closed_room(db, person, name, ids)
  end
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
  answer = try Database.with_connection(pool) do |db| settings_answer(conn, db, id) end
  return ok(respond(conn, answer))
end

def settings_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return shown_settings(db, person, id)
  end
end

def shown_settings(db: Db.Connection, person: Auth.User, id: Optional[Int]) -> Result[Answer]
  room = try closed_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) if not Rooms.editable?(found, person.id, person.role) -> return ok(Answer.Forbidden)
    some(found) -> return ok(Answer.Page(200, try first_settings(db, person, found)))
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
  room = try closed_room(db, person, id)
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
  return change_settings(db, person, room, name, ids, was)
end

def change_settings(
  db: Db.Connection,
  person: Auth.User,
  room: Rooms.Room,
  name: String,
  ids: List[Int],
  was: List[Int],
) -> Result[Answer]
  people = try Rooms.people(db, person.id)
  chosen = chosen_of(people, ids)
  problem = Rooms.name_problem(name)
  if problem != ""
    page = try settings_form(db, person, room, name, chosen, chosen_of(people, was), problem)
    return ok(Answer.Page(422, page))
  end

  changed = try Rooms.update_closed(db, room.id, person.id, name, chosen, was)
  # The check before the form said they may; a refusal now is a change that happened meanwhile (they were taken out,
  # or lost the role), so they are told what a person who is not in the room is.
  if not changed
    return ok(Answer.NotFound)
  end

  # The people the form took out lose the stream of the room's messages, which was checked when they subscribed.
  removed = was.select do |id| id != person.id and not chosen.include?(id) end
  return ok(Answer.Made(room.id, person.id, true, removed))
end

# The form as it is first drawn: the people in the room are checked, and are the ones that it remembers as in it.
def first_settings(db: Db.Connection, person: Auth.User, room: Rooms.Room) -> Result[String]
  members = try Rooms.member_ids(db, room.id)
  return settings_form(db, person, room, room.name, members, members, "")
end

# A refused form comes back with what was typed and checked, and with the `was` that it had, so that fixing the name
# still takes out the people that it unchecked.
def settings_form(
  db: Db.Connection,
  person: Auth.User,
  room: Rooms.Room,
  name: String,
  chosen: List[Int],
  was: List[Int],
  message: String,
) -> Result[String]
  people = try Rooms.people(db, person.id)
  return ok(Views.room_settings(try sidebar_of(db, person), room, name, people, chosen, was, message))
end

# The form of Rails posts to the room with `_method=delete`; any other post is what a `POST` to the path was before the
# form existed (the router's own answer), a 405 that says which methods the path takes, whatever the room.
def post_room(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  methods = try Bond.form_all(conn, "_method")
  if methods.empty? or methods[0] != Routes.ROOM_DELETE_METHOD
    return ok(respond(conn, Answer.NotAllowed(Routes.ROOM_ALLOW)))
  end

  return delete_room(conn, pool)
end

# The task that deletes the messages starts after the connection is given back, from the task of the request.
def delete_room(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  id = room_id(conn)
  answer = try Database.with_connection(pool) do |db| delete_answer(conn, db, id) end
  case answer
    Answer.Deleted(deleted) ->
      RoomDeletion.start(pool, deleted)
      return ok(respond(conn, answer))
    _ -> return ok(respond(conn, answer))
  end
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
  done = try Rooms.destroy_later(db, room.id, person.id)
  if not done
    return ok(Answer.NotFound)
  end

  return ok(Answer.Deleted(room.id))
end

def show_room(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  pages: Optional[PageCache.Pages],
) -> Result[Bond.Conn]
  before = try cursor(conn)
  id = room_id(conn)
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(respond(conn, Answer.SignedOut))
    some(person) -> return shown_room(conn, pool, cable, cache, pages, person, id, before)
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
  person: Auth.User,
  id: Optional[Int],
  before: Optional[Int],
) -> Result[Bond.Conn]
  spot = PageCache.spot(pages, PageCache.ROOM, person, id, before)
  kept = PageCache.lookup(spot)
  case kept
    some(page) -> return ok(respond(conn, Answer.Cached(page)))
    none -> return made_room_page(conn, pool, cable, cache, spot, person, id, before)
  end
end

def made_room_page(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  cache: Optional[Cache.Store],
  spot: Optional[PageCache.Spot],
  person: Auth.User,
  id: Optional[Int],
  before: Optional[Int],
) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| room_answer(db, cable, cache, person, id, before) end
  return ok(respond(conn, kept(spot, answer)))
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

# The messages that come before `?before=ID` (the newest 40 without it), as the fragment that the script of the page
# puts in the list: no layout, no sidebar. Rails answers 204 when there is nothing to add, and so does this.
def older_messages(
  conn: Bond.Conn,
  pool: Database.Pool,
  cache: Optional[Cache.Store],
  pages: Optional[PageCache.Pages],
) -> Result[Bond.Conn]
  before = try cursor(conn)
  id = room_id(conn)
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(respond(conn, Answer.SignedOut))
    some(person) -> return older_page(conn, pool, cache, pages, person, id, before)
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
) -> Result[Bond.Conn]
  spot = PageCache.spot(pages, PageCache.MESSAGES, person, id, before)
  found = PageCache.lookup(spot)
  case found
    some(page) -> return ok(respond(conn, Answer.Cached(page)))
    none -> return made_older_page(conn, pool, cache, spot, person, id, before)
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
) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| older_fragment(db, cache, person, id, before) end
  return ok(respond(conn, kept(spot, answer)))
end

def older_fragment(
  db: Db.Connection,
  cache: Optional[Cache.Store],
  person: Auth.User,
  id: Optional[Int],
  before: Optional[Int],
) -> Result[Answer]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) -> return ok(fragment_of(cache, try Rooms.page(db, found.id, before)))
  end
end

def fragment_of(cache: Optional[Cache.Store], page: Rooms.Page) -> Answer
  if page.messages.empty?
    return Answer.NoContent
  end

  return Answer.Fragment(MessageCache.list(cache, page.messages))
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
  thread = MessageCache.list(cache, page.messages)
  return ok(
    Views.room(
      try sidebar_of(db, person),
      room,
      page,
      thread,
      form,
      Rooms.editable?(room, person.id, person.role),
      CableWeb.room_sources(cable, room.id),
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

# A room of the person that is closed: the settings exist for no other kind, so another kind is as missing as a room
# of other people.
def closed_room(db: Db.Connection, person: Auth.User, id: Optional[Int]) -> Result[Optional[Rooms.Room]]
  room = try member_room(db, person, id)
  case room
    some(found) if found.room_type == Rooms.CLOSED -> return ok(room)
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

# `?before=ID`, the message that the page shows the ones before. A value that is not a number is a 400.
def cursor(conn: Bond.Conn) -> Result[Optional[Int]]
  values = try Bond.query_all(conn, "before")
  if values.empty?
    return ok(none)
  end

  parsed = values[0].to_i
  if not parsed.ok?
    return Bond.bad_request("before must be a whole number")
  end

  return ok(some(parsed.unwrap!))
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
        Bond.html(conn, 200, Views.message_stream(room, message)),
        "content-type",
        TURBO_STREAM_TYPE + "; charset=utf-8",
      )
    Answer.Posted(room, _, _) -> return Bond.redirect(conn, Routes.room_path(room.id))
    Answer.NoContent -> return Bond.status(conn, 204)
    Answer.Redirect(path) -> return Bond.redirect(conn, path)
    Answer.NotFound -> return Bond.text(conn, 404, Routes.MISSING)
    Answer.NotAllowed(allow) -> return Bond.header(Bond.text(conn, 405, "method not allowed"), "allow", allow)
    Answer.Forbidden -> return Bond.text(conn, 403, "Forbidden")
    Answer.Deleted(_) -> return Bond.redirect(conn, Routes.HOME)
    Answer.SignedOut -> return Bond.redirect(conn, Routes.SIGN_IN)
  end
end

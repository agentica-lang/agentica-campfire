## The web side of rooms and messages: the forms of a new room (open, closed or direct), a room page, the settings of
## a closed room and the post of a message. Each handler opens one connection and does everything on it, the person
## included (`AuthWeb.current_user_in`). The sign-in filter of `AuthWeb` has let in only a person with a session, but
## the session may have ended since, so a handler that finds nobody sends the visitor to sign in.
##
## A room that the person is not in is answered 404 with the same body as a room that was never made, before anything
## about the room (or the form posted to it) is looked at, so no answer tells that a room exists. The settings are
## only for a closed room: for a room of another kind the person is in, they are the same 404. In a closed room only its
## maker and an account administrator may change it, and another member is answered 403.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Auth from "auth"
import AuthWeb from "auth_web"
import Database from "database"
import Rooms from "rooms"
import Routes from "routes"
import Views from "views"
import {Config} from "config"

# Bytes of randomness in the `client_message_id` of a form, which is that many bytes in hex.
CLIENT_ID_BYTES = 16

# What a handler makes of its request, decided while its connection is open and answered after it is closed.
enum Answer
  Page(Int, String)
  Redirect(String)
  NotFound
  Forbidden
  SignedOut
end

## Adds the routes of the rooms to `app`. They are not in `AuthWeb.PUBLIC_PATHS`, so they need a sign-in.
export def add(app: Bond.App, config: Config) -> Bond.App
  return (
    app
    |> Bond.get(Routes.ROOM_NEW) do |conn| show_new_room(conn, config) end
    |> Bond.post(Routes.ROOMS) do |conn| create_room(conn, config) end
    |> Bond.get(Routes.ROOM) do |conn| show_room(conn, config) end
    |> Bond.post(Routes.ROOM_MESSAGES) do |conn| create_message(conn, config) end
    |> Bond.get(Routes.CLOSED_ROOM_NEW) do |conn| show_new_closed_room(conn, config) end
    |> Bond.post(Routes.CLOSED_ROOMS) do |conn| create_closed_room(conn, config) end
    |> Bond.get(Routes.DIRECT_ROOM_NEW) do |conn| show_new_direct_room(conn, config) end
    |> Bond.post(Routes.DIRECT_ROOMS) do |conn| create_direct_room(conn, config) end
    |> Bond.get(Routes.ROOM_SETTINGS) do |conn| show_settings(conn, config) end
    |> Bond.post(Routes.ROOM_SETTINGS) do |conn| save_settings(conn, config) end
  )
end

## The home page of the person: their sidebar and nothing else yet.
export def home(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  answer = try Database.with_connection(config.database_url) do |db| home_answer(conn, db) end
  return ok(respond(conn, answer))
end

def home_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return ok(Answer.Page(200, Views.home(try sidebar_of(db, person))))
  end
end

def show_new_room(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  answer = try Database.with_connection(config.database_url) do |db| new_room_answer(conn, db) end
  return ok(respond(conn, answer))
end

def new_room_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return ok(Answer.Page(200, Views.new_room(try sidebar_of(db, person), "", "")))
  end
end

def create_room(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  name = (try Bond.form(conn, "name")).strip
  answer = try Database.with_connection(config.database_url) do |db| create_room_answer(conn, db, name) end
  return ok(respond(conn, answer))
end

def create_room_answer(conn: Bond.Conn, db: Db.Connection, name: String) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
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
  return ok(Answer.Redirect(Routes.room_path(room_id)))
end

def show_new_closed_room(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  answer = try Database.with_connection(config.database_url) do |db| new_closed_room_answer(conn, db) end
  return ok(respond(conn, answer))
end

def new_closed_room_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return ok(Answer.Page(200, try closed_room_form(db, person, "", [], "")))
  end
end

def create_closed_room(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  name = (try Bond.form(conn, "name")).strip
  ids = try ids_of(conn, "member")
  answer = try Database.with_connection(config.database_url) do |db| create_closed_answer(conn, db, name, ids) end
  return ok(respond(conn, answer))
end

def create_closed_answer(conn: Bond.Conn, db: Db.Connection, name: String, ids: List[Int]) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
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
  return ok(Answer.Redirect(Routes.room_path(room_id)))
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

def show_new_direct_room(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  answer = try Database.with_connection(config.database_url) do |db| new_direct_room_answer(conn, db) end
  return ok(respond(conn, answer))
end

def new_direct_room_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return ok(Answer.Page(200, try direct_room_form(db, person, [], "")))
  end
end

def create_direct_room(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  ids = try ids_of(conn, "member")
  answer = try Database.with_connection(config.database_url) do |db| create_direct_answer(conn, db, ids) end
  return ok(respond(conn, answer))
end

def create_direct_answer(conn: Bond.Conn, db: Db.Connection, ids: List[Int]) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
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
    some(found) -> return ok(Answer.Redirect(Routes.room_path(found)))
  end
end

def direct_room_form(db: Db.Connection, person: Auth.User, chosen: List[Int], message: String) -> Result[String]
  people = try Rooms.people(db, person.id)
  return ok(Views.new_direct_room(try sidebar_of(db, person), people, chosen, message))
end

def show_settings(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  id = room_id(conn)
  answer = try Database.with_connection(config.database_url) do |db| settings_answer(conn, db, id) end
  return ok(respond(conn, answer))
end

def settings_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
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

def save_settings(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  id = room_id(conn)
  answer = try Database.with_connection(config.database_url) do |db| save_settings_answer(conn, db, id) end
  return ok(respond(conn, answer))
end

def save_settings_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
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

  return ok(Answer.Redirect(Routes.room_path(room.id)))
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

def show_room(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  before = try cursor(conn)
  id = room_id(conn)
  answer = try Database.with_connection(config.database_url) do |db| room_answer(conn, db, id, before) end
  return ok(respond(conn, answer))
end

def room_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int], before: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return shown_room(db, person, id, before)
  end
end

def shown_room(db: Db.Connection, person: Auth.User, id: Optional[Int], before: Optional[Int]) -> Result[Answer]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) -> return ok(Answer.Page(200, try room_page(db, person, found, before, composer("", ""))))
  end
end

def create_message(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  # What a form of this app always has, so a missing or odd value is a request that no page of ours made (a 400),
  # whatever the room: nothing here depends on the room.
  body = (try Bond.form(conn, "body")).strip
  sent_id = try client_id(conn)
  id = room_id(conn)
  answer = try Database.with_connection(config.database_url) do |db| message_answer(conn, db, id, body, sent_id) end
  return ok(respond(conn, answer))
end

def message_answer(
  conn: Bond.Conn,
  db: Db.Connection,
  id: Optional[Int],
  body: String,
  sent_id: String,
) -> Result[Answer]
  user = try AuthWeb.current_user_in(conn, db)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return posted(db, person, id, body, sent_id)
  end
end

# Membership first: a refusal of the text must not tell a person who is not in a room that it exists.
def posted(db: Db.Connection, person: Auth.User, id: Optional[Int], body: String, sent_id: String) -> Result[Answer]
  room = try member_room(db, person, id)
  case room
    none -> return ok(Answer.NotFound)
    some(found) -> return post_to(db, person, found, body, sent_id)
  end
end

def post_to(db: Db.Connection, person: Auth.User, room: Rooms.Room, body: String, sent_id: String) -> Result[Answer]
  problem = Rooms.body_problem(body)
  if problem != ""
    page = try room_page(db, person, room, none, composer(problem, body))
    return ok(Answer.Page(422, page))
  end

  try Rooms.post(db, room.id, person.id, sent_id, body)
  return ok(Answer.Redirect(Routes.room_path(room.id)))
end

# A page of the room with a form that has a new id, so that sending it again after a refusal is a new message.
def room_page(
  db: Db.Connection,
  person: Auth.User,
  room: Rooms.Room,
  before: Optional[Int],
  form: Views.Composer,
) -> Result[String]
  page = try Rooms.page(db, room.id, before)
  return ok(Views.room(try sidebar_of(db, person), room, page, form, Rooms.editable?(room, person.id, person.role)))
end

def composer(note: String, draft: String) -> Views.Composer
  return Views.Composer(note: note, draft: draft, message_id: SecureRandom.hex(CLIENT_ID_BYTES))
end

def sidebar_of(db: Db.Connection, person: Auth.User) -> Result[String]
  rooms = try Rooms.visible(db, person.id)
  return ok(Views.sidebar(person.name, rooms))
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
    some(found) if found.kind == Rooms.CLOSED -> return ok(room)
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
  values = try Bond.form_all(conn, "client_message_id")
  if values.empty? or values[0].empty?
    return ok(SecureRandom.hex(CLIENT_ID_BYTES))
  end

  if values[0].length > Rooms.MAX_CLIENT_ID_LENGTH
    return Bond.bad_request("client_message_id is at most #{Rooms.MAX_CLIENT_ID_LENGTH} characters")
  end

  return ok(values[0])
end

def respond(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Page(status, html) -> return Bond.html(conn, status, html)
    Answer.Redirect(path) -> return Bond.redirect(conn, path)
    Answer.NotFound -> return Bond.text(conn, 404, Routes.MISSING)
    Answer.Forbidden -> return Bond.text(conn, 403, "Forbidden")
    Answer.SignedOut -> return Bond.redirect(conn, Routes.SIGN_IN)
  end
end

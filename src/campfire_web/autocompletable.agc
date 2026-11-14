## The people that a mention may name (`Autocompletable::UsersController` of Rails): `GET /autocompletable/users` gives
## the prompt items of the editor and `GET /autocompletable/users.json` the same people as JSON. `room_id` keeps the
## people of that room, which the person must be in (else the 404 of any missing page); `filter` (the editor) or
## `query` keeps the names that hold it; `page` is a page of `Rooms.CANDIDATES_PAGE`, from 1. Only active people.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import HTML from "std/html"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import AvatarsWeb from "avatars"
import Blocks from "blocks"
import Database from "../campfire/repo/database"
import Mentions from "../campfire/mentions"
import Rooms from "../campfire/rooms"
import Routes from "routes"
import Views from "views"

## Adds the two routes to `app`. They are not in `AuthWeb.PUBLIC_PATHS`, so they need a sign-in. `key` signs the links
## of the pictures (`AvatarsWeb.link`).
def add(app: Bond.App, pool: Database.Pool, key: Optional[Bytes]) -> Bond.App
  on_get_html = Blocks.handler do |conn| index(conn, pool, key, false) end
  on_get_json = Blocks.handler do |conn| index(conn, pool, key, true) end
  (
    app
    |> Bond.get(Routes.AUTOCOMPLETE_USERS, on_get_html)
    |> Bond.get(Routes.AUTOCOMPLETE_USERS_JSON, on_get_json)
  )
end

private

# The most of a page that is looked for, so an offset stays small.
MAX_PAGE = 1000

# Rails' JSON of a person: the name escaped as HTML (`h(user.name)`), the id and the link of the picture (`null`
# without the key of `SECRET_KEY_BASE`); `gid` stands for Rails' `sgid`.
struct Candidate
  name: String
  value: Int
  avatar_url: Optional[String]
  gid: String
end

def index(conn: Bond.Conn, pool: Database.Pool, key: Optional[Bytes], json: Bool) -> Result[Bond.Conn]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Bond.redirect(conn, Routes.SIGN_IN))
    some(person) -> listed(conn, pool, key, json, person)
  end
end

def listed(
  conn: Bond.Conn,
  pool: Database.Pool,
  key: Optional[Bytes],
  json: Bool,
  person: Auth.User,
) -> Result[Bond.Conn]
  query = Bond.query(conn, "filter").unwrap_or("")
  if query.empty?
    query = Bond.query(conn, "query").unwrap_or("")
  end

  page = Bond.query(conn, "page").unwrap_or("1").to_i.unwrap_or(1).clamp(1, MAX_PAGE)
  room = Bond.query(conn, "room_id").unwrap_or("")
  found = try Database.with_connection(pool) do |db| people_of(db, person, room, query.strip, page) end
  case found
    none -> ok(Bond.text(conn, 404, Routes.MISSING))
    some(people) -> ok(AuthWeb.private_page(answer(conn, key, json, people)))
  end
end

# `none` for a room that the person is not in, or a `room_id` that is not a number.
def people_of(
  db: Db.Connection,
  person: Auth.User,
  room: String,
  query: String,
  page: Int,
) -> Result[Optional[List[Rooms.Candidate]]]
  return ok(some(try Rooms.candidates(db, none, query, page))) if room.empty?

  id = room.to_i
  return ok(none) if not id.ok?

  found = try Rooms.find(db, person.id, id.unwrap!)
  return ok(none) if found.none?

  ok(some(try Rooms.candidates(db, some(id.unwrap!), query, page)))
end

def answer(conn: Bond.Conn, key: Optional[Bytes], json: Bool, people: List[Rooms.Candidate]) -> Bond.Conn
  if json
    candidates = people.map do |p|
      avatar = AvatarsWeb.link(key, p.id, p.updated_at)
      avatar_url: Optional[String] = none
      if not avatar.empty?
        avatar_url = some(avatar)
      end

      Candidate(name: HTML.escape(p.name), value: p.id, avatar_url: avatar_url, gid: Mentions.gid(p.id))
    end

    return Bond.json(conn, 200, JSON.from(candidates))
  end

  items = people.map do |p|
    Views.PromptItem(id: p.id, name: p.name, avatar: AvatarsWeb.link(key, p.id, p.updated_at))
  end

  Bond.html(conn, 200, Views.prompt_items(items))
end

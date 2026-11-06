## The web side of the people of the account: the people page, which an administrator also uses to see the join link
## and make a new one, and the posts that deactivate and reactivate a person. They are not in `AuthWeb.PUBLIC_PATHS`,
## so they need a sign-in. Everything but the page is for administrators only: another person is answered 403 before
## the person that the path names is looked at, and `Accounts` checks the role again inside its transaction. The page
## holds the join code, so it is kept out of caches and out of the `Referer` of the links on it.

import Bond from "pkg/bond/bond"
import Channels from "pkg/channels/channels"
import Db from "pkg/db/db"
import Accounts from "../campfire/accounts"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import Database from "../campfire/repo/database"
import Hangup from "hangup"
import Rooms from "../campfire/rooms"
import Routes from "routes"
import Views from "views"
import {Config} from "../campfire/config"

# What a reactivation of a person whose address is another account's now is told.
CONFLICT = "That address belongs to another account now"

# What a handler makes of its request, decided while its connection is open and answered after it is closed.
enum Answer
  Page(String)
  Redirect(String)
  NotFound
  Forbidden
  Conflict
  SignedOut
end

## Adds the routes of the people page to `app`.
export def add(app: Bond.App, config: Config, pool: Database.Pool, hub: Channels.Hub) -> Bond.App
  return (
    app
    |> Bond.get(Routes.USERS) do |conn| show_users(conn, config, pool) end
    |> Bond.post(Routes.USER_DEACTIVATE) do |conn| change_user(conn, pool, hub, true) end
    |> Bond.post(Routes.USER_REACTIVATE) do |conn| change_user(conn, pool, hub, false) end
    |> Bond.post(Routes.JOIN_CODE) do |conn| regenerate_code(conn, pool) end
  )
end

def show_users(conn: Bond.Conn, config: Config, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| users_answer(conn, db, config) end
  return ok(respond(conn, answer))
end

def users_answer(conn: Bond.Conn, db: Db.Connection, config: Config) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return ok(Answer.Page(try users_page(db, config, person)))
  end
end

def users_page(db: Db.Connection, config: Config, person: Auth.User) -> Result[String]
  admin = person.role == Rooms.ADMINISTRATOR_ROLE_NAME
  people = try Accounts.people(db, admin)
  link = ""
  if admin
    link = try join_link(db, config)
  end

  rooms = try Rooms.visible(db, person.id)
  return ok(Views.users(Views.sidebar(person.name, rooms), people, person.id, admin, link))
end

# The address of the app, when it is configured (it is needed for email), and else only the path, which the
# administrator puts after the address that they reach the app by: the `Host` of a request is the visitor's to choose.
def join_link(db: Db.Connection, config: Config) -> Result[String]
  code = try Accounts.join_code(db)
  return ok("#{config.base_url}#{Routes.join_path(code)}")
end

# A deactivated person has no session left, so their sockets are closed and told not to come back (`Hangup`). A repeat
# of the click does it again, which costs nothing.
def change_user(conn: Bond.Conn, pool: Database.Pool, hub: Channels.Hub, deactivating: Bool) -> Result[Bond.Conn]
  id = user_id(conn)
  answer = try Database.with_connection(pool) do |db| change_answer(conn, db, id, deactivating) end
  case answer
    Answer.Redirect(_) if deactivating and id.some? -> Hangup.user(hub, id.unwrap!, false)
    _ -> return ok(respond(conn, answer))
  end

  return ok(respond(conn, answer))
end

def change_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int], deactivating: Bool) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) if person.role != Rooms.ADMINISTRATOR_ROLE_NAME -> return ok(Answer.Forbidden)
    some(person) -> return changed_user(db, person, id, deactivating)
  end
end

def changed_user(db: Db.Connection, person: Auth.User, id: Optional[Int], deactivating: Bool) -> Result[Answer]
  case id
    none -> return ok(Answer.NotFound)
    some(user_id) -> return answer_of(try apply_change(db, person, user_id, deactivating))
  end
end

def apply_change(db: Db.Connection, person: Auth.User, user_id: Int, deactivating: Bool) -> Result[Accounts.Change]
  if deactivating
    return Accounts.deactivate(db, person.id, user_id)
  end

  return Accounts.reactivate(db, person.id, user_id)
end

# `Unchanged` goes back to the page like `Changed`: a second click on a button that was already used is not a failure.
def answer_of(change: Accounts.Change) -> Result[Answer]
  case change
    Accounts.Change.Changed -> return ok(Answer.Redirect(Routes.USERS))
    Accounts.Change.Unchanged -> return ok(Answer.Redirect(Routes.USERS))
    Accounts.Change.Missing -> return ok(Answer.NotFound)
    Accounts.Change.Refused -> return ok(Answer.Forbidden)
    Accounts.Change.Taken -> return ok(Answer.Conflict)
  end
end

def regenerate_code(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| regenerate_answer(conn, db) end
  return ok(respond(conn, answer))
end

def regenerate_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) if person.role != Rooms.ADMINISTRATOR_ROLE_NAME -> return ok(Answer.Forbidden)
    some(person) -> return regenerated(db, person)
  end
end

def regenerated(db: Db.Connection, person: Auth.User) -> Result[Answer]
  done = try Accounts.regenerate_join_code(db, person.id)
  if not done
    return ok(Answer.Forbidden)
  end

  return ok(Answer.Redirect(Routes.USERS))
end

# A user id that is not a whole number names nobody, which is a 404 like any other.
def user_id(conn: Bond.Conn) -> Optional[Int]
  parsed = Bond.param(conn, "id").unwrap_or("").to_i
  if parsed.ok?
    return some(parsed.unwrap!)
  end

  return none
end

def respond(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Page(html) -> return AuthWeb.private_page(Bond.html(conn, 200, html))
    Answer.Redirect(path) -> return Bond.redirect(conn, path)
    Answer.NotFound -> return Bond.text(conn, 404, Routes.MISSING)
    Answer.Forbidden -> return Bond.text(conn, 403, "Forbidden")
    Answer.Conflict -> return Bond.text(conn, 409, CONFLICT)
    Answer.SignedOut -> return Bond.redirect(conn, Routes.SIGN_IN)
  end
end

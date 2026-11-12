## The web side of the chat bots of the account (`Accounts::BotsController` and `Accounts::Bots::KeysController`): the
## list, the forms, and the posts that make, rename and deactivate a bot and give it a new key. They are for
## administrators only: anybody else is answered 403 before the bot that the path names is looked at, and `Bots` checks
## the role again inside its transaction. Then come the 404 of a bot that is not an active one, and the form (400 when
## it has no field, 422 for a name that is refused). The pages hold the keys, so they are kept out of caches.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Accounts from "../campfire/accounts"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import Blocks from "blocks"
import BotMessagesWeb from "bot_messages"
import Bots from "../campfire/bots"
import Database from "../campfire/repo/database"
import Rooms from "../campfire/rooms"
import RoomsWeb from "rooms"
import Routes from "routes"
import Views from "views"
import {Config} from "../campfire/config"

# The name of the field of Rails' form (`params.require(:user)`).
USER_NAME = "user[name]"

# What a handler makes of its request, decided while its connection is open and answered after it is closed.
enum Answer
  Page(String)
  Refused(String)
  NotAllowed(String)
  Redirect(String)
  NotFound
  Forbidden
  SignedOut
end

# Who asks: an administrator, or the answer that anybody else gets.
enum Actor
  Administrator(Auth.User)
  Turned(Answer)
end

## Adds the routes of the chat bots to `app`. `config` says where the curl lines of the list start.
export def add(app: Bond.App, pool: Database.Pool, config: Config) -> Bond.App
  on_get_bots = Blocks.handler() do |conn|
    respond(conn, pool) do |_, db, person| list_answer(db, person, BotMessagesWeb.origin(conn, config)) end
  end

  on_post_bots = Blocks.handler() do |conn| respond(conn, pool, &create_answer) end
  on_get_bot_new = Blocks.handler() do |conn| respond(conn, pool, &new_answer) end
  on_get_bot_edit = Blocks.handler() do |conn| respond(conn, pool, &edit_answer) end
  on_post_bot = Blocks.handler() do |conn| post_bot(conn, pool) end
  on_patch_bot = Blocks.handler() do |conn| respond(conn, pool, &rename_answer) end
  on_put_bot = Blocks.handler() do |conn| respond(conn, pool, &rename_answer) end
  on_delete_bot = Blocks.handler() do |conn| respond(conn, pool, &remove_answer) end
  on_post_bot_key = Blocks.handler() do |conn| post_key(conn, pool) end

  (
    app
    |> Bond.get(Routes.BOTS, on_get_bots)
    |> Bond.post(Routes.BOTS, on_post_bots)
    |> Bond.get(Routes.BOT_NEW, on_get_bot_new)
    |> Bond.get(Routes.BOT_EDIT, on_get_bot_edit)
    |> Bond.post(Routes.BOT, on_post_bot)
    |> Bond.patch(Routes.BOT, on_patch_bot)
    |> Bond.put(Routes.BOT, on_put_bot)
    |> Bond.delete(Routes.BOT, on_delete_bot)
    |> Bond.post(Routes.BOT_KEY, on_post_bot_key)
    |> Bond.put(Routes.BOT_KEY) do |conn| respond(conn, pool, &key_answer) end
  )
end

# A `POST` with `_method` set to `patch` or `put` renames the bot and one set to `delete` removes it, as the forms of
# Rails send them; any other is a 405.
def post_bot(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  return respond(conn, pool, &rename_answer) if method == Routes.METHOD_PATCH or method == Routes.METHOD_PUT

  return respond(conn, pool, &remove_answer) if method == Routes.METHOD_DELETE

  ok(answered(conn, Answer.NotAllowed(Routes.BOT_ALLOW)))
end

def post_key(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  return respond(conn, pool, &key_answer) if method == Routes.METHOD_PUT

  ok(answered(conn, Answer.NotAllowed(Routes.BOT_KEY_ALLOW)))
end

def respond(
  conn: Bond.Conn,
  pool: Database.Pool,
  handle: Fn[Bond.Conn, Db.Connection, Auth.User, Result[Answer]],
) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| gated(conn, db, handle) end
  ok(answered(conn, answer))
end

def gated(
  conn: Bond.Conn,
  db: Db.Connection,
  handle: Fn[Bond.Conn, Db.Connection, Auth.User, Result[Answer]],
) -> Result[Answer]
  asked = try actor(conn)
  case asked
    Actor.Turned(turned) -> ok(turned)
    Actor.Administrator(person) -> handle.call(conn, db, person)
  end
end

# Each bot with the rooms it is in but the direct ones, which the curl lines of the list post to.
def list_answer(db: Db.Connection, person: Auth.User, origin: String) -> Result[Answer]
  bots = try Bots.active(db)
  entries: List[Views.BotRooms] = []
  for bot in bots
    rooms = try Rooms.memberships(db, bot.id)
    shared = rooms.select do |room| room.room_type != Rooms.DIRECT end
    entries = entries.push(Views.BotRooms(bot: bot, rooms: shared))
  end

  ok(Answer.Page(Views.bots(try RoomsWeb.sidebar_of(db, person), entries, origin)))
end

def new_answer(_conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Answer]
  ok(Answer.Page(Views.bot_form(try RoomsWeb.sidebar_of(db, person), none, "", "")))
end

def edit_answer(conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Answer]
  found = try find(conn, db)
  case found
    none -> ok(Answer.NotFound)
    some(bot) -> ok(Answer.Page(Views.bot_form(try RoomsWeb.sidebar_of(db, person), found, bot.name, "")))
  end
end

def create_answer(conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Answer]
  name = (try Bond.form(conn, USER_NAME)).strip
  problem = Bots.name_problem(name)
  return ok(Answer.Refused(Views.bot_form(try RoomsWeb.sidebar_of(db, person), none, name, problem))) if problem != ""

  done = try Bots.create(db, person.id, name)
  return ok(Answer.Forbidden) if not done

  ok(Answer.Redirect(Routes.BOTS))
end

def rename_answer(conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Answer]
  found = try find(conn, db)
  case found
    none -> ok(Answer.NotFound)
    some(bot) -> renamed(conn, db, person, bot)
  end
end

def renamed(conn: Bond.Conn, db: Db.Connection, person: Auth.User, bot: Bots.Bot) -> Result[Answer]
  name = (try Bond.form(conn, USER_NAME)).strip
  problem = Bots.name_problem(name)
  if problem != ""
    return ok(Answer.Refused(Views.bot_form(try RoomsWeb.sidebar_of(db, person), some(bot), name, problem)))
  end

  answer_of(try Bots.rename(db, person.id, bot.id, name))
end

def remove_answer(conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Answer]
  id = bot_id(conn)
  return ok(Answer.NotFound) if id.none?

  answer_of(try Bots.deactivate(db, person.id, id.unwrap!))
end

def key_answer(conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Answer]
  id = bot_id(conn)
  return ok(Answer.NotFound) if id.none?

  answer_of(try Bots.reset_key(db, person.id, id.unwrap!))
end

def actor(conn: Bond.Conn) -> Result[Actor]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Actor.Turned(Answer.SignedOut))
    some(person) if person.role != Rooms.ADMINISTRATOR_ROLE_NAME -> ok(Actor.Turned(Answer.Forbidden))
    some(person) -> ok(Actor.Administrator(person))
  end
end

# The active bot that the path names; an id that is not a whole number names nobody.
def find(conn: Bond.Conn, db: Db.Connection) -> Result[Optional[Bots.Bot]]
  id = bot_id(conn)
  return ok(none) if id.none?

  Bots.find(db, id.unwrap!)
end

def bot_id(conn: Bond.Conn) -> Optional[Int]
  parsed = Bond.param(conn, "id").unwrap_or("").to_i
  return some(parsed.unwrap!) if parsed.ok?

  none
end

def answer_of(change: Accounts.Change) -> Result[Answer]
  case change
    Accounts.Change.Changed -> ok(Answer.Redirect(Routes.BOTS))
    Accounts.Change.Unchanged -> ok(Answer.Redirect(Routes.BOTS))
    Accounts.Change.Missing -> ok(Answer.NotFound)
    Accounts.Change.Refused -> ok(Answer.Forbidden)
    Accounts.Change.Taken -> ok(Answer.Forbidden)
  end
end

def answered(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Page(html) -> AuthWeb.private_page(Bond.html(conn, 200, html))
    Answer.Refused(html) -> AuthWeb.private_page(Bond.html(conn, 422, html))
    Answer.NotAllowed(allow) -> Bond.header(Bond.text(conn, 405, "method not allowed"), "allow", allow)
    Answer.Redirect(path) -> Bond.redirect(conn, path)
    Answer.NotFound -> Bond.text(conn, 404, Routes.MISSING)
    Answer.Forbidden -> Bond.text(conn, 403, "Forbidden")
    Answer.SignedOut -> Bond.redirect(conn, Routes.SIGN_IN)
  end
end

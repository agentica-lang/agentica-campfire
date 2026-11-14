## The web side of the people of the account: the account settings page (the name of the account, and for an
## administrator the role and the removal of each person), the people page, which an administrator also uses to see
## the join link and make a new one, and the posts that deactivate and reactivate a person. They are not in
## `AuthWeb.PUBLIC_PATHS`, so they need a sign-in. Everything but the page is for administrators only: another person
## is answered 403 before the person that the path names is looked at, and `Accounts` checks the role again inside its
## transaction. The page holds the join code, so it is kept out of caches and out of the `Referer` of the links on it.

import Bond from "pkg/bond/bond"
import Channels from "pkg/channels/channels"
import Db from "pkg/db/db"
import Accounts from "../campfire/accounts"
import Auth from "../campfire/auth"
import BanFlag from "ban_flag"
import Bans from "../campfire/bans"
import Blocks from "blocks"
import CableWeb from "cable"
import ContentRemoval from "content_removal"
import AuthWeb from "auth"
import Database from "../campfire/repo/database"
import Hangup from "hangup"
import Rooms from "../campfire/rooms"
import RoomsWeb from "rooms"
import Routes from "routes"
import Views from "views"
import {Config} from "../campfire/config"

## Adds the routes of the people page to `app`.
def add(app: Bond.App, config: Config, pool: Database.Pool, cable: CableWeb.Cable, bans: ATS[String, Int]) -> Bond.App
  hub = cable.hub
  on_get_users = Blocks.handler do |conn| show_users(conn, config, pool) end
  on_post_user_deactivate = Blocks.handler do |conn| change_user(conn, pool, hub, true) end
  on_post_user_reactivate = Blocks.handler do |conn| change_user(conn, pool, hub, false) end
  on_post_user_ban = Blocks.handler do |conn| post_ban(conn, pool, cable, bans, config.storage_dir) end
  on_delete_user_ban = Blocks.handler do |conn| change_ban(conn, pool, cable, bans, false, config.storage_dir) end
  on_post_join_code = Blocks.handler do |conn| regenerate_code(conn, pool) end
  on_get_account_edit = Blocks.handler do |conn| show_account(conn, pool) end
  on_post_account = Blocks.handler do |conn| post_account(conn, pool) end
  on_patch_account = Blocks.handler do |conn| rename_account(conn, pool) end
  on_post_account_user = Blocks.handler do |conn| post_account_user(conn, pool, hub) end
  on_patch_account_user = Blocks.handler do |conn| set_role(conn, pool) end

  (
    app
    |> Bond.get(Routes.USERS, on_get_users)
    |> Bond.post(Routes.USER_DEACTIVATE, on_post_user_deactivate)
    |> Bond.post(Routes.USER_REACTIVATE, on_post_user_reactivate)
    |> Bond.post(Routes.USER_BAN, on_post_user_ban)
    |> Bond.delete(Routes.USER_BAN, on_delete_user_ban)
    |> Bond.post(Routes.JOIN_CODE, on_post_join_code)
    |> Bond.get(Routes.ACCOUNT_EDIT, on_get_account_edit)
    |> Bond.post(Routes.ACCOUNT, on_post_account)
    |> Bond.patch(Routes.ACCOUNT, on_patch_account)
    |> Bond.post(Routes.ACCOUNT_USER, on_post_account_user)
    |> Bond.patch(Routes.ACCOUNT_USER, on_patch_account_user)
    |> Bond.delete(Routes.ACCOUNT_USER) do |conn| remove_person(conn, pool, hub) end
  )
end

private

# What a reactivation of a person whose address is another account's now is told.
CONFLICT = "That address belongs to another account now"
# The names of the fields of Rails' forms (`params.require(:account)` and `params.require(:user)`).
ACCOUNT_NAME = "account[name]"
USER_ROLE = "user[role]"
RESTRICT_FIELD = "account[settings][restrict_room_creation_to_administrators]"
# What a save of the switch of who may make rooms with a value that is not `true` or `false` is told.
RESTRICT_REFUSED = "Choose on or off"
# What a save of a role that is neither is told.
ROLE_REFUSED = "Choose member or administrator"

# What a handler makes of its request, decided while its connection is open and answered after it is closed.
enum Answer
  Page(String)
  Refused(String)
  NotAllowed(String)
  Redirect(String)
  Banned(Int)
  NotFound
  Forbidden
  Conflict
  SignedOut
end

# A `POST` with no `_method` is the ban button of Rails and one with `_method` set to `delete` is the button that
# lifts it;
# any other is a 405 that lists the methods of the path.
def post_ban(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  bans: ATS[String, Int],
  storage_dir: String,
) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  return change_ban(conn, pool, cable, bans, true, storage_dir) if method == ""

  return change_ban(conn, pool, cable, bans, false, storage_dir) if method == Routes.METHOD_DELETE

  ok(respond(conn, Answer.NotAllowed(Routes.USER_BAN_ALLOW)))
end

# A banned person has no session left, so their sockets are closed and told not to come back, and their messages are
# taken away by a task, which tells the rooms (`RemoveBannedContentJob`). Only a ban that changed something
# does either.
def change_ban(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  bans: ATS[String, Int],
  banning: Bool,
  storage_dir: String,
) -> Result[Bond.Conn]
  id = user_id(conn)
  answer = try Database.with_connection(pool) do |db| ban_answer(conn, db, id, bans, banning) end
  case answer
    Answer.Banned(banned_id) ->
      Hangup.user(cable.hub, banned_id, false)
      _ = ContentRemoval.start(pool, cable, banned_id, storage_dir)
    _ -> nil
  end

  ok(respond(conn, answer))
end

# Administrator first (403), then the person (404), as the other administrator-only posts.
def ban_answer(
  conn: Bond.Conn,
  db: Db.Connection,
  id: Optional[Int],
  bans: ATS[String, Int],
  banning: Bool,
) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) if person.role != Rooms.ADMINISTRATOR_ROLE_NAME -> ok(Answer.Forbidden)
    some(_) if id.none? -> ok(Answer.NotFound)
    some(person) -> banned_answer(db, person, id.unwrap!, bans, banning)
  end
end

# The flag of the bans is set before a ban is written, so a request from the address cannot slip in between, and read
# again after a ban is lifted.
def banned_answer(
  db: Db.Connection,
  person: Auth.User,
  user_id: Int,
  bans: ATS[String, Int],
  banning: Bool,
) -> Result[Answer]
  if banning
    BanFlag.mark(bans, true)
    change = try Bans.ban(db, person.id, user_id)
    case change
      Accounts.Change.Changed ->
        # Again after the commit: a lifting that read the table in between would have cleared it.
        BanFlag.mark(bans, true)
        return ok(Answer.Banned(user_id))
      _ -> return answer_of(change, Routes.user_path(user_id))
    end
  end

  lifted = try Bans.unban(db, person.id, user_id)
  _ = try BanFlag.refresh(bans, db)
  answer_of(lifted, Routes.user_path(user_id))
end

def show_account(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| account_answer(conn, db) end
  ok(respond(conn, answer))
end

def account_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) -> ok(Answer.Page(try account_page(db, person, "", none)))
  end
end

# The page for the person. `typed` is the name that was refused, put back in the box, and `note` says why.
def account_page(db: Db.Connection, person: Auth.User, note: String, typed: Optional[String]) -> Result[String]
  admin = person.role == Rooms.ADMINISTRATOR_ROLE_NAME
  name = try Accounts.name(db)
  people = try Accounts.people(db, false)
  # Only an administrator sees the switch.
  restricted = false
  if admin
    restricted = try Accounts.room_creation_restricted?(db)
  end

  shown = typed.unwrap_or(name)
  ok(Views.account(try RoomsWeb.sidebar_of(db, person), shown, people, person.id, admin, restricted, note))
end

# A `POST` is the form of Rails with `_method` set to `patch`; any other is a 405 that lists the methods of the path.
def post_account(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  return ok(respond(conn, Answer.NotAllowed(Routes.ACCOUNT_ALLOW))) if method != Routes.METHOD_PATCH

  rename_account(conn, pool)
end

def rename_account(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| rename_answer(conn, db) end
  ok(respond(conn, answer))
end

# An administrator only, checked before the form is read, as `ensure_can_administer` runs before the action in Rails.
def rename_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) if person.role != Rooms.ADMINISTRATOR_ROLE_NAME -> ok(Answer.Forbidden)
    some(person) -> renamed(conn, db, person)
  end
end

# The form of the account page has two parts, the name and the switch of who may make rooms, and a request has either
# or both (Rails permits `name` and `settings`). One with neither is a 400. A part is checked before anything is saved.
def renamed(conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Answer]
  names = try Bond.form_all(conn, ACCOUNT_NAME)
  flags = try Bond.form_all(conn, RESTRICT_FIELD)
  return Bond.bad_request("#{ACCOUNT_NAME} is missing") if names.empty? and flags.empty?

  name: Optional[String] = none
  if not names.empty?
    name = some(names[0].strip)
    problem = Accounts.name_problem(name.unwrap!)
    return ok(Answer.Refused(try account_page(db, person, problem, name))) if problem != ""
  end

  restricted: Optional[Bool] = none
  if not flags.empty?
    if flags[0] != "true" and flags[0] != "false"
      return ok(Answer.Refused(try account_page(db, person, RESTRICT_REFUSED, none)))
    end

    restricted = some(flags[0] == "true")
  end

  done = try Accounts.save(db, person.id, name, restricted)
  return ok(Answer.Forbidden) if not done

  ok(Answer.Redirect(Routes.ACCOUNT_EDIT))
end

# A `POST` with `_method` set to `patch` saves a role and one set to `delete` removes the person; any other is a 405.
def post_account_user(conn: Bond.Conn, pool: Database.Pool, hub: Channels.Hub) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  return set_role(conn, pool) if method == Routes.METHOD_PATCH

  return remove_person(conn, pool, hub) if method == Routes.METHOD_DELETE

  ok(respond(conn, Answer.NotAllowed(Routes.ACCOUNT_USER_ALLOW)))
end

def set_role(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  id = user_id(conn)
  answer = try Database.with_connection(pool) do |db| role_answer(conn, db, id) end
  ok(respond(conn, answer))
end

# Administrator first (403), then the person (404), then the form (400), as Rails runs its filters and then reads the
# parameters.
def role_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) if person.role != Rooms.ADMINISTRATOR_ROLE_NAME -> ok(Answer.Forbidden)
    some(person) -> roled(conn, db, person, id)
  end
end

def roled(conn: Bond.Conn, db: Db.Connection, person: Auth.User, id: Optional[Int]) -> Result[Answer]
  case id
    none -> ok(Answer.NotFound)
    some(user_id) if not (try Accounts.active_person?(db, user_id)) -> ok(Answer.NotFound)
    some(user_id) -> roled_person(conn, db, person, user_id)
  end
end

# Rails takes anything but `administrator` for `member`; a value that is neither is refused here instead, so a form
# that is not ours cannot step a person down.
def roled_person(conn: Bond.Conn, db: Db.Connection, person: Auth.User, user_id: Int) -> Result[Answer]
  role = try Bond.form(conn, USER_ROLE)
  if role != Rooms.ADMINISTRATOR_ROLE_NAME and role != Rooms.MEMBER_ROLE_NAME
    return ok(Answer.Refused(try account_page(db, person, ROLE_REFUSED, none)))
  end

  change = try Accounts.set_role(db, person.id, user_id, role == Rooms.ADMINISTRATOR_ROLE_NAME)
  answer_of(change, Routes.ACCOUNT_EDIT)
end

# Administrator first (403), then the person (404: nobody active, so a person who is deactivated already is not removed
# twice), as Rails runs `User.active.find`. The sockets of a person who was removed are closed and told not to come
# back (`Hangup`), as for the deactivation on the people page.
def remove_person(conn: Bond.Conn, pool: Database.Pool, hub: Channels.Hub) -> Result[Bond.Conn]
  id = user_id(conn)
  answer = try Database.with_connection(pool) do |db| removal_answer(conn, db, id) end
  case answer
    Answer.Redirect(_) if id.some? -> Hangup.user(hub, id.unwrap!, false)
    _ -> return ok(respond(conn, answer))
  end

  ok(respond(conn, answer))
end

def removal_answer(conn: Bond.Conn, db: Db.Connection, id: Optional[Int]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) if person.role != Rooms.ADMINISTRATOR_ROLE_NAME -> ok(Answer.Forbidden)
    some(_) if id.none? -> ok(Answer.NotFound)
    some(_) if not (try Accounts.active_person?(db, id.unwrap!)) -> ok(Answer.NotFound)
    some(person) -> answer_of(try Accounts.deactivate(db, person.id, id.unwrap!), Routes.ACCOUNT_EDIT)
  end
end

def show_users(conn: Bond.Conn, config: Config, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| users_answer(conn, db, config) end
  ok(respond(conn, answer))
end

def users_answer(conn: Bond.Conn, db: Db.Connection, config: Config) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) -> ok(Answer.Page(try users_page(db, config, person)))
  end
end

def users_page(db: Db.Connection, config: Config, person: Auth.User) -> Result[String]
  admin = person.role == Rooms.ADMINISTRATOR_ROLE_NAME
  people = try Accounts.people(db, admin)
  link = ""
  if admin
    link = try join_link(db, config)
  end

  ok(Views.users(try RoomsWeb.sidebar_of(db, person), people, person.id, admin, link))
end

# The address of the app, when it is configured (it is needed for email), and else only the path, which the
# administrator puts after the address that they reach the app by: the `Host` of a request is the visitor's to choose.
def join_link(db: Db.Connection, config: Config) -> Result[String]
  code = try Accounts.join_code(db)
  ok("#{config.base_url}#{Routes.join_path(code)}")
end

# A deactivated person has no session left, so their sockets are closed and told not to come back (`Hangup`). A repeat
# of the click does it again, which costs nothing.
def change_user(conn: Bond.Conn, pool: Database.Pool, hub: Channels.Hub, deactivating: Bool) -> Result[Bond.Conn]
  id = user_id(conn)
  answer = try Database.with_connection(pool) do |db| change_answer(conn, db, id, deactivating, Routes.USERS) end
  case answer
    Answer.Redirect(_) if deactivating and id.some? -> Hangup.user(hub, id.unwrap!, false)
    _ -> return ok(respond(conn, answer))
  end

  ok(respond(conn, answer))
end

# `back` is the page that the person goes back to: the people page, or the account settings for the same change there.
def change_answer(
  conn: Bond.Conn,
  db: Db.Connection,
  id: Optional[Int],
  deactivating: Bool,
  back: String,
) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) if person.role != Rooms.ADMINISTRATOR_ROLE_NAME -> ok(Answer.Forbidden)
    some(person) -> changed_user(db, person, id, deactivating, back)
  end
end

def changed_user(
  db: Db.Connection,
  person: Auth.User,
  id: Optional[Int],
  deactivating: Bool,
  back: String,
) -> Result[Answer]
  case id
    none -> ok(Answer.NotFound)
    some(user_id) -> answer_of(try apply_change(db, person, user_id, deactivating), back)
  end
end

def apply_change(db: Db.Connection, person: Auth.User, user_id: Int, deactivating: Bool) -> Result[Accounts.Change]
  return Accounts.deactivate(db, person.id, user_id) if deactivating

  Accounts.reactivate(db, person.id, user_id)
end

# `Unchanged` goes back to the page like `Changed`: a second click on a button that was already used is not a failure.
def answer_of(change: Accounts.Change, back: String) -> Result[Answer]
  case change
    Accounts.Change.Changed -> ok(Answer.Redirect(back))
    Accounts.Change.Unchanged -> ok(Answer.Redirect(back))
    Accounts.Change.Missing -> ok(Answer.NotFound)
    Accounts.Change.Refused -> ok(Answer.Forbidden)
    Accounts.Change.Taken -> ok(Answer.Conflict)
  end
end

def regenerate_code(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| regenerate_answer(conn, db) end
  ok(respond(conn, answer))
end

def regenerate_answer(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) if person.role != Rooms.ADMINISTRATOR_ROLE_NAME -> ok(Answer.Forbidden)
    some(person) -> regenerated(db, person)
  end
end

def regenerated(db: Db.Connection, person: Auth.User) -> Result[Answer]
  done = try Accounts.regenerate_join_code(db, person.id)
  return ok(Answer.Forbidden) if not done

  ok(Answer.Redirect(Routes.USERS))
end

# A user id that is not a whole number names nobody, which is a 404 like any other.
def user_id(conn: Bond.Conn) -> Optional[Int]
  parsed = Bond.param(conn, "id").unwrap_or("").to_i
  return some(parsed.unwrap!) if parsed.ok?

  none
end

def respond(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Page(html) -> AuthWeb.private_page(Bond.html(conn, 200, html))
    Answer.Refused(html) -> AuthWeb.private_page(Bond.html(conn, 422, html))
    Answer.NotAllowed(allow) -> Bond.header(Bond.text(conn, 405, "method not allowed"), "allow", allow)
    Answer.Redirect(path) -> Bond.redirect(conn, path)
    Answer.Banned(user_id) -> Bond.redirect(conn, Routes.user_path(user_id))
    Answer.NotFound -> Bond.text(conn, 404, Routes.MISSING)
    Answer.Forbidden -> Bond.text(conn, 403, "Forbidden")
    Answer.Conflict -> Bond.text(conn, 409, CONFLICT)
    Answer.SignedOut -> Bond.redirect(conn, Routes.SIGN_IN)
  end
end

## The web side of the profile: the page of a user (`GET /users/ID`, for any signed-in person) and the profile of the
## person who is signed in (`GET` and `PATCH /users/me/profile`). They are not in `AuthWeb.PUBLIC_PATHS`, so they need
## a sign-in. The checks run in the order of the other write routes: no session redirects to sign-in, then the person
## (404 for a profile that is not theirs), then the form (400 for a missing part, 422 for a part that does not do).
## The profile is private to the person (an email address, a password field), so it is kept out of caches and out of
## the `Referer` of the links on it.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import Database from "../campfire/repo/database"
import Passwords from "../campfire/passwords"
import Profiles from "../campfire/profiles"
import Rooms from "../campfire/rooms"
import RoomsWeb from "rooms"
import Routes from "routes"
import SignedId from "../campfire/signed_id"
import Slots from "../campfire/slots"
import Views from "views"

# The names of the fields of Rails' form (`params.require(:user)`).
FIELD_NAME = "user[name]"
FIELD_EMAIL = "user[email_address]"
FIELD_PASSWORD = "user[password]"
FIELD_BIO = "user[bio]"

# The `:id` that the links use for the person who is signed in.
ME = "me"

# What a handler makes of its request, decided while its connection is open and answered after it is closed.
enum Answer
  Page(Int, String)
  NotAllowed
  Redirect(String)
  Busy(String)
  NotFound
  SignedOut
end

# The form as a person sent it. A part that is not in the request is `none` (Rails' `compact` drops it), and a request
# with none of the four is a 400, as `params.require(:user)` is.
struct Form
  name: Optional[String]
  email: Optional[String]
  password: Optional[String]
  bio: Optional[String]
end

## Adds the routes of the user page and of the profile to `app`. `slots` is the bound on hashing that the sign-in shares,
## and `key` is `SignedId.key` of the `SECRET_KEY_BASE`, `none` without one (no page then shows a picture).
export def add(app: Bond.App, pool: Database.Pool, slots: ATS[String, Int], key: Optional[Bytes]) -> Bond.App
  return (
    app
    |> Bond.get(Routes.USER) do |conn| show_user(conn, pool, key) end
    |> Bond.get(Routes.PROFILE) do |conn| show_profile(conn, pool, key) end
    |> Bond.post(Routes.PROFILE) do |conn| post_profile(conn, pool, slots, key) end
    |> Bond.patch(Routes.PROFILE) do |conn| save_profile(conn, pool, slots, key) end
    |> Bond.put(Routes.PROFILE) do |conn| save_profile(conn, pool, slots, key) end
  )
end

def show_user(conn: Bond.Conn, pool: Database.Pool, key: Optional[Bytes]) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| user_answer(conn, db, key) end
  return ok(respond(conn, answer))
end

def user_answer(conn: Bond.Conn, db: Db.Connection, key: Optional[Bytes]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return user_of(conn, db, person, key)
  end
end

# A user in any status has a page (Rails' `User.find`); an id that is not a whole number names nobody.
def user_of(conn: Bond.Conn, db: Db.Connection, person: Auth.User, key: Optional[Bytes]) -> Result[Answer]
  parsed = Bond.param(conn, "id").unwrap_or("").to_i
  if not parsed.ok?
    return ok(Answer.NotFound)
  end

  found = try Profiles.find(db, parsed.unwrap!)
  case found
    none -> return ok(Answer.NotFound)
    some(profile) ->
      admin = person.role == Rooms.ADMINISTRATOR_ROLE_NAME
      page = Views.user_page(
        try RoomsWeb.sidebar_of(db, person),
        profile,
        person.id,
        admin,
        avatar_of(key, profile.id),
      )

      return ok(Answer.Page(200, page))
  end
end

def show_profile(conn: Bond.Conn, pool: Database.Pool, key: Optional[Bytes]) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| profile_answer(conn, db, key) end
  return ok(respond(conn, answer))
end

def profile_answer(conn: Bond.Conn, db: Db.Connection, key: Optional[Bytes]) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) if not own?(conn, person) -> return ok(Answer.NotFound)
    some(person) -> return ok(Answer.Page(200, try profile_form(db, person, key, none, "")))
  end
end

# A `POST` is the form of Rails with `_method` set to `patch` (or `put`, which the router takes too); any other is
# a 405
# that lists the methods of the path.
def post_profile(
  conn: Bond.Conn,
  pool: Database.Pool,
  slots: ATS[String, Int],
  key: Optional[Bytes],
) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  if method != Routes.METHOD_PATCH and method != Routes.METHOD_PUT
    return ok(respond(conn, Answer.NotAllowed))
  end

  return save_profile(conn, pool, slots, key)
end

def save_profile(
  conn: Bond.Conn,
  pool: Database.Pool,
  slots: ATS[String, Int],
  key: Optional[Bytes],
) -> Result[Bond.Conn]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(respond(conn, Answer.SignedOut))
    some(person) if not own?(conn, person) -> return ok(respond(conn, Answer.NotFound))
    some(person) -> return saved(conn, pool, slots, key, person)
  end
end

def saved(
  conn: Bond.Conn,
  pool: Database.Pool,
  slots: ATS[String, Int],
  key: Optional[Bytes],
  person: Auth.User,
) -> Result[Bond.Conn]
  form = try form_of(conn)
  if form.name.none? and form.email.none? and form.password.none? and form.bio.none?
    return Bond.bad_request("#{FIELD_NAME} is missing")
  end

  problem = try Database.with_connection(pool) do |db|
    Profiles.problem(db, person.id, form.name, form.email, form.password, form.bio)
  end

  if problem != ""
    return ok(respond(conn, Answer.Page(422, try refused(pool, person, key, form, problem))))
  end

  digest: Optional[String] = none
  password = form.password.unwrap_or("")
  if not password.empty?
    if not Slots.take?(slots, AuthWeb.MAX_HASHES)
      return ok(
        respond(conn, Answer.Busy(try refused(pool, person, key, form, "Too many requests. Try again in a moment."))),
      )
    end

    hashed = Passwords.hash(password)
    Slots.release(slots)
    digest = some(try hashed)
  end

  change = try Database.with_connection(pool) do |db|
    Profiles.save(db, person.id, form.name, form.email, digest, form.bio)
  end

  case change
    Profiles.Change.Saved -> return ok(respond(conn, Answer.Redirect(Routes.profile_path())))
    Profiles.Change.Taken ->
      return ok(respond(conn, Answer.Page(422, try refused(pool, person, key, form, Profiles.EMAIL_TAKEN))))
    Profiles.Change.Gone -> return ok(respond(conn, Answer.SignedOut))
  end
end

def form_of(conn: Bond.Conn) -> Result[Form]
  return ok(
    Form(
      name: try first_of(conn, FIELD_NAME),
      email: try first_of(conn, FIELD_EMAIL),
      password: try first_of(conn, FIELD_PASSWORD),
      bio: try first_of(conn, FIELD_BIO),
    ),
  )
end

def first_of(conn: Bond.Conn, field: String) -> Result[Optional[String]]
  values = try Bond.form_all(conn, field)
  if values.empty?
    return ok(none)
  end

  return ok(some(values[0]))
end

# The profile page again for a refused save, with what the person typed (the password is never put back).
def refused(pool: Database.Pool, person: Auth.User, key: Optional[Bytes], form: Form, note: String) -> Result[String]
  return Database.with_connection(pool) do |db| profile_form(db, person, key, some(form), note) end
end

def profile_form(
  db: Db.Connection,
  person: Auth.User,
  key: Optional[Bytes],
  typed: Optional[Form],
  note: String,
) -> Result[String]
  found = try Profiles.find(db, person.id)
  stored = found.unwrap!
  shown = stored
  if typed.some?
    form = typed.unwrap!
    shown = Profiles.Detail(
      id: stored.id,
      name: form.name.unwrap_or(stored.name),
      email: form.email.unwrap_or(stored.email),
      bio: form.bio.unwrap_or(stored.bio),
      role: stored.role,
      status: stored.status,
      updated_at: stored.updated_at,
    )
  end

  rooms = try Rooms.memberships(db, person.id)
  return ok(Views.profile_page(try RoomsWeb.sidebar_of(db, person), shown, rooms, avatar_of(key, person.id), note))
end

# The profile is the signed-in person's: `:id` is `me`, or their own id. The profile of another user is 404.
def own?(conn: Bond.Conn, person: Auth.User) -> Bool
  id = Bond.param(conn, "id").unwrap_or("")
  return id == ME or id == "#{person.id}"
end

# The path of the picture of the user, "" when the app has no key to sign it with.
def avatar_of(key: Optional[Bytes], user_id: Int) -> String
  if key.none?
    return ""
  end

  token = SignedId.generate(key.unwrap!, user_id, SignedId.AVATAR_PURPOSE)
  if not token.ok?
    return ""
  end

  return "/users/#{token.unwrap!}/avatar"
end

def respond(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Page(status, html) -> return AuthWeb.private_page(Bond.html(conn, status, html))
    Answer.NotAllowed -> return Bond.header(Bond.text(conn, 405, "method not allowed"), "allow", Routes.PROFILE_ALLOW)
    Answer.Redirect(path) -> return Bond.redirect(conn, path)
    Answer.Busy(html) -> return AuthWeb.private_page(Bond.header(Bond.html(conn, 503, html), "retry-after", "5"))
    Answer.NotFound -> return Bond.text(conn, 404, Routes.MISSING)
    Answer.SignedOut -> return Bond.redirect(conn, Routes.SIGN_IN)
  end
end

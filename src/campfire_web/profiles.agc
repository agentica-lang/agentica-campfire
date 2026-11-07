## The web side of the profile: the page of a user (`GET /users/ID`, for any signed-in person) and the profile of the
## person who is signed in (`GET` and `PATCH /users/me/profile`). They are not in `AuthWeb.PUBLIC_PATHS`, so they need
## a sign-in. The checks run in the order of the other write routes: no session redirects to sign-in, then the person
## (404 for a profile that is not theirs), then the form (400 for a missing part, 422 for a part that does not do).
## The profile is private to the person (an email address, a password field), so it is kept out of caches and out of
## the `Referer` of the links on it.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Auth from "../campfire/auth"
import Avatars from "../campfire/avatars"
import Channels from "pkg/channels/channels"
import Hangup from "hangup"
import RateLimit from "../campfire/rate_limit"
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
import {Config} from "../campfire/config"

# The names of the fields of Rails' form (`params.require(:user)`).
FIELD_NAME = "user[name]"
FIELD_EMAIL = "user[email_address]"
FIELD_PASSWORD = "user[password]"
FIELD_BIO = "user[bio]"
FIELD_CHALLENGE = "user[password_challenge]"

# A person may try their current password this many times in this long (Rails' `rate_limit` of the sign-in).
CHALLENGE_ATTEMPTS = 10
CHALLENGE_WINDOW_MS = 180_000
TOO_MANY = "Too many attempts, try again later"

# The `:id` that the links use for the person who is signed in.
ME = "me"

# What a handler makes of its request, decided while its connection is open and answered after it is closed.
enum Answer
  Page(Int, String)
  NotAllowed(String)
  Redirect(String)
  Busy(String)
  Limited(String, Int)
  NotFound
  SignedOut
end

# What the check of a new password gave: its digest (`none` when there is no new password), or the answer to send.
enum Hashed
  Digest(Optional[String])
  Refused(Answer)
end

# The form as a person sent it. A part that is not in the request is `none` (Rails' `compact` drops it), and a request
# with none of the four is a 400, as `params.require(:user)` is.
struct Form
  name: Optional[String]
  email: Optional[String]
  password: Optional[String]
  challenge: String
  bio: Optional[String]
end

# What the handlers share: the settings, the pool, the hashing slots, the attempts of the current password by person,
# the key of the avatar links (`none` without one) and the hub whose sockets a new password ends.
struct Env
  config: Config
  pool: Database.Pool
  slots: ATS[String, Int]
  attempts: ATS[String, Int]
  key: Optional[Bytes]
  hub: Channels.Hub
end

## Adds the routes of the user page and of the profile to `app`. `slots` is the bound on hashing that the sign-in
## shares, and `key` is `SignedId.key` of the `SECRET_KEY_BASE`, `none` without one (no page then shows a picture). A
## new password ends the other sessions of the person, and `hub` their sockets.
export def add(
  app: Bond.App,
  config: Config,
  pool: Database.Pool,
  slots: ATS[String, Int],
  key: Optional[Bytes],
  hub: Channels.Hub,
) -> Bond.App
  env = Env(config: config, pool: pool, slots: slots, attempts: RateLimit.new(), key: key, hub: hub)
  return (
    app
    |> Bond.get(Routes.USER) do |conn| show_user(conn, env) end
    |> Bond.get(Routes.PROFILE) do |conn| show_profile(conn, env) end
    |> Bond.post(Routes.PROFILE) do |conn| post_profile(conn, env) end
    |> Bond.patch(Routes.PROFILE) do |conn| save_profile(conn, env) end
    |> Bond.put(Routes.PROFILE) do |conn| save_profile(conn, env) end
    |> Bond.post(Routes.AVATAR) do |conn| post_avatar(conn, env) end
    |> Bond.delete(Routes.AVATAR) do |conn| remove_avatar(conn, env) end
  )
end

def show_user(conn: Bond.Conn, env: Env) -> Result[Bond.Conn]
  answer = try Database.with_connection(env.pool) do |db| user_answer(conn, db, env.key) end
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
        avatar_of(key, profile.id, profile.updated_at),
      )

      return ok(Answer.Page(200, page))
  end
end

def show_profile(conn: Bond.Conn, env: Env) -> Result[Bond.Conn]
  answer = try Database.with_connection(env.pool) do |db| profile_answer(conn, db, env.key) end
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
def post_profile(conn: Bond.Conn, env: Env) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  if method != Routes.METHOD_PATCH and method != Routes.METHOD_PUT
    return ok(respond(conn, Answer.NotAllowed(Routes.PROFILE_ALLOW)))
  end

  return save_profile(conn, env)
end

def save_profile(conn: Bond.Conn, env: Env) -> Result[Bond.Conn]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(respond(conn, Answer.SignedOut))
    some(person) if not own?(conn, person) -> return ok(respond(conn, Answer.NotFound))
    some(person) -> return saved(conn, env, person)
  end
end

# The button of Rails' profile: a `POST` with `_method` set to `delete`; any other is a 405 that lists the methods of
# the path.
def post_avatar(conn: Bond.Conn, env: Env) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  if method != Routes.METHOD_DELETE
    return ok(respond(conn, Answer.NotAllowed(Routes.AVATAR_ALLOW)))
  end

  return remove_avatar(conn, env)
end

# Takes the picture of the person away (the sign-in first, then the person: 404 for the picture of another) and goes
# back to the profile. A person with none is the same redirect (Rails would fail on it). The files go once the rows
# have committed; a file that cannot be deleted is left with a warning, since the rows no longer name it. (The stdlib
# has no delete for a plain file: `Path.remove` also takes a folder, but the path here is made by `Avatars.path` from
# a checked key, so it is never one.)
def remove_avatar(conn: Bond.Conn, env: Env) -> Result[Bond.Conn]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(respond(conn, Answer.SignedOut))
    some(person) if not own?(conn, person) -> return ok(respond(conn, Answer.NotFound))
    some(person) -> return removed(conn, env, person)
  end
end

def removed(conn: Bond.Conn, env: Env, person: Auth.User) -> Result[Bond.Conn]
  keys = try Database.with_connection(env.pool) do |db| Avatars.remove(db, person.id) end
  for key in keys
    path = Avatars.path(env.config.storage_dir, key)
    if path.some?
      gone = Path.remove(path.unwrap!)
      if not gone.ok?
        IO.warn("campfire: the file of the avatar blob #{key} could not be deleted: #{gone.message}")
      end
    end
  end

  return ok(respond(conn, Answer.Redirect(Routes.profile_path())))
end

def saved(conn: Bond.Conn, env: Env, person: Auth.User) -> Result[Bond.Conn]
  form = try form_of(conn)
  if form.name.none? and form.email.none? and form.password.none? and form.bio.none?
    return Bond.bad_request("#{FIELD_NAME} is missing")
  end

  problem = try Database.with_connection(env.pool) do |db|
    Profiles.problem(db, person.id, form.name, form.email, form.password, form.bio)
  end

  if problem != ""
    return ok(respond(conn, Answer.Page(422, try refusal(env, person, form, problem))))
  end

  hashed = try new_digest(conn, env, person, form)
  case hashed
    Hashed.Refused(answer) -> return ok(respond(conn, answer))
    Hashed.Digest(digest) -> return stored(conn, env, person, form, digest)
  end
end

# The hash of the new password, if there is one. Setting one needs the current password (`password_challenge`), tried
# at most `CHALLENGE_ATTEMPTS` times in `CHALLENGE_WINDOW_MS` for each person, and checked in the same hashing slot
# as the
# new hash, since both are slow; a request that cannot get a slot is told to come back, and one with a wrong or missing
# current password is refused with nothing saved.
def new_digest(conn: Bond.Conn, env: Env, person: Auth.User, form: Form) -> Result[Hashed]
  password = form.password.unwrap_or("")
  if password.empty?
    return ok(Hashed.Digest(none))
  end

  wait = RateLimit.hit(env.attempts, "user:#{person.id}", Time.monotonic_ms(), CHALLENGE_ATTEMPTS, CHALLENGE_WINDOW_MS)
  if wait > 0
    return ok(Hashed.Refused(Answer.Limited(try refusal(env, person, form, TOO_MANY), wait)))
  end

  if not Slots.take?(env.slots, AuthWeb.MAX_HASHES)
    return ok(Hashed.Refused(Answer.Busy(try refusal(env, person, form, "Too many requests. Try again in a moment."))))
  end

  digest = digest_if_current(env, person, form.challenge, password)
  Slots.release(env.slots)
  case try digest
    none -> return ok(Hashed.Refused(Answer.Page(422, try refusal(env, person, form, Profiles.CHALLENGE_PROBLEM))))
    some(value) -> return ok(Hashed.Digest(some(value)))
  end
end

# The digest of `password` when `challenge` is the current password, else `none`.
def digest_if_current(env: Env, person: Auth.User, challenge: String, password: String) -> Result[Optional[String]]
  right = try Database.with_connection(env.pool) do |db|
    Profiles.challenge_ok?(db, person.id, challenge, env.config.bcrypt_library)
  end

  if not right
    return ok(none)
  end

  return ok(some(try Passwords.hash(password)))
end

# The save. A new password ends the other sessions of the person, and so their sockets: the ones of this browser
# connect again with the session that stays.
def stored(conn: Bond.Conn, env: Env, person: Auth.User, form: Form, digest: Optional[String]) -> Result[Bond.Conn]
  change = try Database.with_connection(env.pool) do |db|
    Profiles.save(db, person.id, form.name, form.email, digest, form.bio, AuthWeb.session_token(conn))
  end

  case change
    Profiles.Change.Saved ->
      if digest.some?
        Hangup.user(env.hub, person.id, true)
      end

      return ok(respond(conn, Answer.Redirect(Routes.profile_path())))
    Profiles.Change.Taken ->
      return ok(respond(conn, Answer.Page(422, try refusal(env, person, form, Profiles.EMAIL_TAKEN))))
    Profiles.Change.Gone -> return ok(respond(conn, Answer.SignedOut))
  end
end

def form_of(conn: Bond.Conn) -> Result[Form]
  return ok(
    Form(
      name: try first_of(conn, FIELD_NAME),
      email: try first_of(conn, FIELD_EMAIL),
      password: try first_of(conn, FIELD_PASSWORD),
      challenge: (try first_of(conn, FIELD_CHALLENGE)).unwrap_or(""),
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

# The profile page again for a refused save, with what the person typed (the passwords are never put back).
def refusal(env: Env, person: Auth.User, form: Form, note: String) -> Result[String]
  return Database.with_connection(env.pool) do |db| profile_form(db, person, env.key, some(form), note) end
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
  removable = try Avatars.attached?(db, person.id)
  return ok(
    Views.profile_page(
      try RoomsWeb.sidebar_of(db, person),
      shown,
      rooms,
      avatar_of(key, person.id, shown.updated_at),
      removable,
      note,
    ),
  )
end

# The profile is the signed-in person's: `:id` is `me`, or their own id. The profile of another user is 404.
def own?(conn: Bond.Conn, person: Auth.User) -> Bool
  id = Bond.param(conn, "id").unwrap_or("")
  return id == ME or id == "#{person.id}"
end

# The path of the picture of the user, "" when the app has no key to sign it with. It ends in `?v=` and the digits of
# `updated_at` (Rails' `fresh_user_avatar`), so a change of the picture, which touches `updated_at`, is a new link and
# the browser does not keep the old picture for the 30 minutes that the answer may be kept.
def avatar_of(key: Optional[Bytes], user_id: Int, updated_at: String) -> String
  if key.none?
    return ""
  end

  token = SignedId.generate(key.unwrap!, user_id, SignedId.AVATAR_PURPOSE)
  if not token.ok?
    return ""
  end

  return "/users/#{token.unwrap!}/avatar?v=#{Avatars.version(updated_at)}"
end

def respond(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Page(status, html) -> return AuthWeb.private_page(Bond.html(conn, status, html))
    Answer.NotAllowed(allow) -> return Bond.header(Bond.text(conn, 405, "method not allowed"), "allow", allow)
    Answer.Redirect(path) -> return Bond.redirect(conn, path)
    Answer.Limited(html, wait) ->
      return AuthWeb.private_page(Bond.header(Bond.html(conn, 429, html), "retry-after", wait.to_s))
    Answer.Busy(html) -> return AuthWeb.private_page(Bond.header(Bond.html(conn, 503, html), "retry-after", "5"))
    Answer.NotFound -> return Bond.text(conn, 404, Routes.MISSING)
    Answer.SignedOut -> return Bond.redirect(conn, Routes.SIGN_IN)
  end
end

## The avatar of a user, `GET /users/TOKEN/avatar`: TOKEN is `user.signed_id(purpose: :avatar)` made by Rails (see
## `SignedId`), and what it names is the WebP that Rails stored for the variant `:square` of the avatar, sent as it is
## on the disk of the Disk service of Active Storage (the app makes no image: libvips does that in Rails). When Rails
## has not made the variant yet, the original image is sent with its own type. A person with no avatar at all gets
## their initials as an SVG, as upstream does for a person; upstream's own picture for a bot is not here, so a bot
## gets initials too. A token that does not verify, a user that does not exist and a file that is gone are the 404 of
## any missing page, and nothing tells which. The answer may be kept by the browser of the person for 30 minutes. The
## route needs a sign-in, as in Rails.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Avatars from "../campfire/avatars"
import Database from "../campfire/repo/database"
import Routes from "routes"
import SignedId from "../campfire/signed_id"
import Views from "views"

# `expires_in 30.minutes, stale_while_revalidate: 1.week` of the controller of Rails, but `private`: Rails
# says `public`,
# yet the route needs a sign-in, so a shared cache must not hand the picture to someone who is not signed in.
CACHE_CONTROL = "private, max-age=1800, stale-while-revalidate=604800"
SVG_TYPE = "image/svg+xml; charset=utf-8"

# What the handler found while its connection was open. The stored file (its path and its type) is sent after it is
# closed, since a download can take long and the connection is not needed for it.
enum Answer
  Stored(String, String)
  Initials(String)
  Missing
end

## Adds the route of the avatars to `app`. `key` is `SignedId.key` of the `SECRET_KEY_BASE`, `none` without one (every
## link is then a 404), and `storage_dir` the folder of the files of Active Storage.
export def add(app: Bond.App, pool: Database.Pool, key: Optional[Bytes], storage_dir: String) -> Bond.App
  return app |> Bond.get(Routes.AVATAR) do |conn| show(conn, pool, key, storage_dir) end
end

def show(conn: Bond.Conn, pool: Database.Pool, key: Optional[Bytes], storage_dir: String) -> Result[Bond.Conn]
  user_id = verified(conn, key)
  case user_id
    none -> return ok(missing(conn))
    some(id) ->
      answer = try Database.with_connection(pool) do |db| answer_for(db, id, storage_dir) end
      return respond(conn, answer)
  end
end

# The user in the token, when it was signed with the key for the purpose of an avatar and has not expired.
def verified(conn: Bond.Conn, key: Optional[Bytes]) -> Optional[Int]
  case key
    none -> return none
    some(secret) ->
      token = Bond.param(conn, "id").unwrap_or("")
      return SignedId.verify(secret, token, SignedId.AVATAR_PURPOSE, Time.now_ms())
  end
end

def answer_for(db: Db.Connection, user_id: Int, storage_dir: String) -> Result[Answer]
  found = try Avatars.find(db, user_id)
  case found
    none -> return ok(Answer.Missing)
    some(avatar) -> return ok(shown(user_id, avatar, storage_dir))
  end
end

# A stored file is sent, or a 404 when its key is no key or its file is not on the disk: a person who has an avatar
# must not be told that they have none. Initials are for a person with no avatar at all.
def shown(user_id: Int, avatar: Avatars.Avatar, storage_dir: String) -> Answer
  case avatar.file_key
    none -> return Answer.Initials(Views.avatar_initials(Avatars.initials(avatar.name), Avatars.color(user_id)))
    some(key) -> return stored(storage_dir, key, avatar.content_type)
  end
end

def stored(storage_dir: String, key: String, content_type: String) -> Answer
  path = Avatars.path(storage_dir, key)
  case path
    none -> return Answer.Missing
    some(file) -> return Answer.Stored(file, content_type)
  end
end

def respond(conn: Bond.Conn, answer: Answer) -> Result[Bond.Conn]
  case answer
    Answer.Stored(path, content_type) -> return sent(conn, path, content_type)
    Answer.Initials(svg) -> return ok(cached(Bond.header(Bond.html(conn, 200, svg), "content-type", SVG_TYPE)))
    Answer.Missing -> return ok(missing(conn))
  end
end

# `Files.send` takes the type from the name of the file, which has none (the key), so it is set here.
def sent(conn: Bond.Conn, path: String, content_type: String) -> Result[Bond.Conn]
  file = Bond.send_file(conn, path)
  if not file.ok?
    return ok(missing(conn))
  end

  return ok(cached(Bond.header(file.unwrap!, "content-type", content_type)))
end

def cached(conn: Bond.Conn) -> Bond.Conn
  return Bond.header(conn, "cache-control", CACHE_CONTROL)
end

def missing(conn: Bond.Conn) -> Bond.Conn
  return Bond.text(conn, 404, Routes.MISSING)
end

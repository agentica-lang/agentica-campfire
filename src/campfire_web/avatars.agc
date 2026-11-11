## The avatar of a user, `GET /users/TOKEN/avatar`: TOKEN is `user.signed_id(purpose: :avatar)` made by Rails (see
## `SignedId`), and what it names is the WebP that Rails stored for the variant `:square` of the avatar, sent as it is
## on the disk of the Disk service of Active Storage (the app makes no image: libvips does that in Rails). When Rails
## has not made the variant yet, the original image is sent with its own type. A person with no avatar at all gets
## their initials as an SVG, as upstream does for a person; upstream's own picture for a bot is not here, so a bot
## gets initials too. A token that does not verify, a user that does not exist and a file that is gone are the 404 of
## any missing page, and nothing tells which. The answer may be kept by the browser of the person for 30 minutes. The
## route needs a sign-in, as in Rails.
##
## What the database says (the initials, or the file to send and its type, or none) is kept in the cache of whole pages
## for the version of the database (`PageCache.shared_spot`), the same for everybody: a new picture, a removed one, a
## rename or any other commit is another version, so it is never older than the database. The sign-in filter reads the
## version for these paths too (`PageCache.cached?`), so a repeat costs the read of the observer, the check of the token
## and the file, and takes no connection of the pool. The file is read each time, so a file that is gone is still a 404.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Avatars from "../campfire/avatars"
import Database from "../campfire/repo/database"
import PageCache from "page_cache"
import Routes from "routes"
import SignedId from "../campfire/signed_id"
import Views from "views"

# `expires_in 30.minutes, stale_while_revalidate: 1.week` of the controller of Rails, but `private`: Rails
# says `public`,
# yet the route needs a sign-in, so a shared cache must not hand the picture to someone who is not signed in.
CACHE_CONTROL = "private, max-age=1800, stale-while-revalidate=604800"
SVG_TYPE = "image/svg+xml; charset=utf-8"

# The marks of the kept forms of an answer (`encode`).
STORED_MARK = "S"
INITIALS_MARK = "I\n"
MISSING_MARK = "M"

# What the handler found while its connection was open. The stored file (its path and its type) is sent after it is
# closed, since a download can take long and the connection is not needed for it.
export enum Answer
  Stored(String, String)
  Initials(String)
  Missing
end

## Adds the route of the avatars to `app`. `key` is `SignedId.key` of the `SECRET_KEY_BASE`, `none` without one (every
## link is then a 404), and `storage_dir` the folder of the files of Active Storage.
export def add(
  app: Bond.App,
  pool: Database.Pool,
  pages: Optional[PageCache.Pages],
  key: Optional[Bytes],
  storage_dir: String,
) -> Bond.App
  app |> Bond.get(Routes.AVATAR) do |conn| show(conn, pool, pages, key, storage_dir) end
end

## The answer in the kept form `text`, `none` for a text that `encode` did not write.
export def decode(text: String) -> Optional[Answer]
  if text.start_with?(STORED_MARK)
    parts = text.split("\n")
    return some(Answer.Stored(parts[2], parts[1])) if parts.size == 3
  end

  if text.start_with?(INITIALS_MARK)
    # The SVG is cut out by bytes: the marks are ASCII, and `String.slice` walks every character of a text that has a
    # non-ASCII one.
    svg = String.from_bytes(text.bytes.drop(INITIALS_MARK.bytesize))
    return some(Answer.Initials(svg.unwrap!)) if svg.ok?
  end

  return some(Answer.Missing) if text == MISSING_MARK

  none
end

## The kept form of an answer: a mark, then its parts. The type and the path of a stored file have no line break (the
## type is checked in `Avatars`, the path is made from a checked key), so the line break separates them.
export def encode(answer: Answer) -> String
  case answer
    Answer.Stored(path, content_type) -> "#{STORED_MARK}\n#{content_type}\n#{path}"
    Answer.Initials(svg) -> INITIALS_MARK + svg
    Answer.Missing -> MISSING_MARK
  end
end

def show(
  conn: Bond.Conn,
  pool: Database.Pool,
  pages: Optional[PageCache.Pages],
  key: Optional[Bytes],
  storage_dir: String,
) -> Result[Bond.Conn]
  user_id = verified(conn, key)
  case user_id
    none -> ok(missing(conn))
    some(id) ->
      # The version is read before the database, so what is kept under it is that of the version or later.
      spot = PageCache.shared_spot(pages, PageCache.seen(conn), PageCache.AVATAR, id.to_s)
      kept = recalled(spot)
      return respond(conn, kept.unwrap!) if kept.some?

      answer = try Database.with_connection(pool) do |db| answer_for(db, id, storage_dir) end
      PageCache.remember(spot, encode(answer))
      respond(conn, answer)
  end
end

# The answer kept at `spot`, if it holds one that this code wrote. Avatar entries share the page store
# (`CAMPFIRE_RESPONSE_CACHE_MB`) with the pages, and the version of the database is in their key.
def recalled(spot: Optional[PageCache.Spot]) -> Optional[Answer]
  kept = PageCache.recall(spot)
  return none if kept.none?

  decode(kept.unwrap!)
end

# The user in the token, when it was signed with the key for the purpose of an avatar and has not expired.
def verified(conn: Bond.Conn, key: Optional[Bytes]) -> Optional[Int]
  case key
    none -> none
    some(secret) ->
      token = Bond.param(conn, "id").unwrap_or("")
      SignedId.verify(secret, token, SignedId.AVATAR_PURPOSE, Time.now_ms())
  end
end

def answer_for(db: Db.Connection, user_id: Int, storage_dir: String) -> Result[Answer]
  found = try Avatars.find(db, user_id)
  case found
    none -> ok(Answer.Missing)
    some(avatar) -> ok(shown(user_id, avatar, storage_dir))
  end
end

# A stored file is sent, or a 404 when its key is no key or its file is not on the disk: a person who has an avatar
# must not be told that they have none. Initials are for a person with no avatar at all.
def shown(user_id: Int, avatar: Avatars.Avatar, storage_dir: String) -> Answer
  case avatar.file_key
    none -> Answer.Initials(Views.avatar_initials(Avatars.initials(avatar.name), Avatars.color(user_id)))
    some(key) -> stored(storage_dir, key, avatar.content_type)
  end
end

def stored(storage_dir: String, key: String, content_type: String) -> Answer
  path = Avatars.path(storage_dir, key)
  case path
    none -> Answer.Missing
    some(file) -> Answer.Stored(file, content_type)
  end
end

def respond(conn: Bond.Conn, answer: Answer) -> Result[Bond.Conn]
  case answer
    Answer.Stored(path, content_type) -> sent(conn, path, content_type)
    Answer.Initials(svg) -> ok(cached(Bond.header(Bond.html(conn, 200, svg), "content-type", SVG_TYPE)))
    Answer.Missing -> ok(missing(conn))
  end
end

# `Files.send` takes the type from the name of the file, which has none (the key), so it is set here.
def sent(conn: Bond.Conn, path: String, content_type: String) -> Result[Bond.Conn]
  file = Bond.send_file(conn, path)
  return ok(missing(conn)) if not file.ok?

  ok(cached(Bond.header(file.unwrap!, "content-type", content_type)))
end

def cached(conn: Bond.Conn) -> Bond.Conn = Bond.header(conn, "cache-control", CACHE_CONTROL)

def missing(conn: Bond.Conn) -> Bond.Conn = Bond.text(conn, 404, Routes.MISSING)

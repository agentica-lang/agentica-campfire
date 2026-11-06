## The cache of whole pages, as Rails Campfire caches the answer of `rooms#show` and `messages#index` (the
## `CachedResponses` concern: `ResponseCache` keeps the finished HTML under a key of the person and the request, and
## drops everything when `PRAGMA data_version` says that any connection committed). The room page and the page of older
## messages are a function of the database, the person, the room and `?before=`, so a page that was made from the
## database as it is now is the page to send again.
##
## Invalidation is the version of the database (`Database.version`), which is in every key: a commit by anyone (a new
## message, an edit, a delete, a change of members, a rename of the room or of a person, a session that is touched, a
## Rails app on the same file) gives the next request a new key, so the old pages are never read again and the cache
## drops them when it needs room. The version is read before the page is made, so a page is never older than the
## version in its key. The person and the room are in the key, so a page is only sent to the person it was made for,
## and only a 200 is kept: a room that is not the person's is a 404 that is looked up each time. The membership check
## that comes with making a page needs no repeat on a hit, since a change of members is a commit and so a new version.
##
## Every page has a weak `ETag` (a digest of its bytes, as `Rack::ETag` writes it) and `Cache-Control: max-age=0,
## private, must-revalidate`, as Rails sends, and a request whose `If-None-Match` has the tag is a 304. The form of a
## room page carries a `client_message_id` drawn when the page is made, so two loads of one person at one version of the
## database share it; the app stores it and uses it for nothing else (a repeat is not dropped), so that costs nothing.

import Bond from "pkg/bond/bond"
import Cache from "std/cache"
import Database from "../campfire/repo/database"

# What a megabyte of `CAMPFIRE_RESPONSE_CACHE_MB` is.
BYTES_PER_MB = 1024 * 1024

# `W/"` and 32 hex digits and `"`: the tag has this length always, so the cached text is the tag followed by the page.
ETAG_WIDTH = 36
ETAG_DIGITS = 32

CACHE_CONTROL = "max-age=0, private, must-revalidate"

## The cache and the connection that watches the database for it.
export struct Pages
  store: Cache.Store
  observer: Database.Observer
end

## A page and its tag.
export struct Page
  etag: String
  body: String
end

## Where a page of a request is kept: the cache and the key (with the version of the database in it).
export struct Spot
  pages: Pages
  key: String
end

## The cache for `megabytes` of pages and its observer of the database at `url`, or `none` for 0, which turns it off.
## An `error` is an observer that does not open.
export def start(megabytes: Int, url: String, checkout_ms: Int) -> Result[Optional[Pages]]
  if megabytes <= 0
    return ok(none)
  end

  observer = try Database.open_observer(url, checkout_ms)
  return ok(some(Pages(store: Cache.memory(megabytes * BYTES_PER_MB), observer: observer)))
end

## Closes the observer of `pages`, if there are any.
export def stop(pages: Optional[Pages]) -> Void
  case pages
    none -> return
    some(found) -> Database.close_observer(found.observer)
  end
end

## Where the page of `kind` ("room" or "messages") of the person `user_id` in the room `room_id` (`before` is the
## cursor) goes, as the database is now: read this before the page is made. `none` when there is no cache, the room is
## no number, or the version cannot be read (the page is then made and not kept).
export def spot(
  pages: Optional[Pages],
  kind: String,
  user_id: Int,
  room_id: Optional[Int],
  before: Optional[Int],
) -> Optional[Spot]
  case pages
    none -> return none
    some(found) -> return spot_of(found, kind, user_id, room_id, before)
  end
end

## The page that is kept at `spot`, if there is one.
export def lookup(spot: Optional[Spot]) -> Optional[Page]
  case spot
    none -> return none
    some(found) -> return unpack(Cache.get(found.pages.store, found.key))
  end
end

## The page for `html`, with its tag, kept at `spot` when there is one.
export def keep(spot: Optional[Spot], html: String) -> Page
  digest = Digest.sha256_hexdigest(html.bytes).slice(0, ETAG_DIGITS)
  etag = "W/\"#{digest}\""
  case spot
    none -> return Page(etag: etag, body: html)
    some(found) -> Cache.put(found.pages.store, found.key, etag + html)
  end

  return Page(etag: etag, body: html)
end

## The answer for `page`: a 304 when `If-None-Match` of the request names its tag, else a 200 with the page.
export def respond(conn: Bond.Conn, page: Page) -> Bond.Conn
  if matches?(conn, page.etag)
    return tagged(Bond.status(conn, 304), page)
  end

  return tagged(Bond.html(conn, 200, page.body), page)
end

def spot_of(pages: Pages, kind: String, user_id: Int, room_id: Optional[Int], before: Optional[Int]) -> Optional[Spot]
  if room_id.none?
    return none
  end

  version = Database.version(pages.observer)
  if not version.ok?
    return none
  end

  cursor = before.map do |id| id.to_s end.unwrap_or("")
  key = "page:#{version.unwrap!}:#{kind}:#{user_id}:#{room_id.unwrap!}:#{cursor}"
  return some(Spot(pages: pages, key: key))
end

def unpack(kept: Optional[String]) -> Optional[Page]
  case kept
    none -> return none
    some(text) ->
      return some(Page(etag: text.slice(0, ETAG_WIDTH), body: text.slice(ETAG_WIDTH, text.length - ETAG_WIDTH)))
  end
end

def tagged(conn: Bond.Conn, page: Page) -> Bond.Conn
  return Bond.header(Bond.header(conn, "etag", page.etag), "cache-control", CACHE_CONTROL)
end

# The weak comparison of RFC 9110: `W/` does not count, and `*` is any page.
def matches?(conn: Bond.Conn, etag: String) -> Bool
  sent = Bond.request_header(conn, "if-none-match")
  if not sent.ok?
    return false
  end

  return sent.unwrap!.split(",").any? do |one|
    tag = one.strip
    tag == "*" or opaque(tag) == opaque(etag)
  end
end

def opaque(tag: String) -> String
  if tag.start_with?("W/")
    return tag.slice(2, tag.length - 2)
  end

  return tag
end

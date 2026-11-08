## The cache of whole pages, as Rails Campfire caches the answer of `rooms#show` and `messages#index` (the
## `CachedResponses` concern: `ResponseCache` keeps the finished HTML under a key of the person and the request, and
## drops everything when `PRAGMA data_version` says that any connection committed). The room page and the page of older
## messages are a function of the database, the person, the room and `?before=` (or `?after=`, the kind `AFTER`), so a
## page that was made from the database as it is now is the page to send again.
##
## Invalidation is the version of the database (`Database.version`), which is in the key of the room page and the
## sidebar, and in the stamp of the pages that are kept in a place of the person (the search and the older messages,
## below): a commit by anyone (a new message, an edit, a delete, a change of members, a rename of the room or of a
## person, a session that is touched, a Rails app on the same file) gives the next request a new key or stamp, so the
## old pages are never read again and the cache drops them when it needs room (or the next page for their place writes
## over them). The version is read before the page is made, so a page is never older than the version it is kept
## with. The person (the id, and a digest of the name and the role, which the sign-in filter looked up after the
## version) and the room are in the key or the stamp, so a page is only sent to the person it was made for, and only a
## 200 is kept: a room that is not the person's is a 404 that is looked up each time. A room page with `?before=` is
## not kept, since one person could fill the cache with a page for every number. The membership check that comes with
## making a page needs no repeat on a hit, since a change of members is a commit and so a new version. When the
## version cannot be read the page is made and not kept.
##
## The sidebar page and the search page are kept the same way (kinds `SIDEBAR` and `SEARCH`, for the person, and for
## the words of the search): they are a function of the database and the person too, and nothing in them depends on
## the request (the signed stream names are the same for every load). The key of the sidebar has no room. A search has
## no cursor to bound it, and the words are the client's, so one person could fill the shared store with a page for
## every query and push out the room pages and the sessions of everybody: a person has `search_slots` places for
## search pages (`CAMPFIRE_SEARCH_PAGES`), chosen by the words, and a page is kept in its place with the version, the
## person and the words it was made for, so a page that is another query's, or an old version's, is a miss and is
## written over. That bounds the search pages of a person at `search_slots` for good (the cost is that two queries of
## one place take turns), and the words longer than the form of the search allows are not kept at all.
##
## The older messages (`?before=`, kind `MESSAGES`, and `?after=`, kind `AFTER`) are keyed by a number that the client
## chooses too, so they are bounded the same way: a person has `cursor_slots` places for each of the two kinds
## (`CAMPFIRE_CURSOR_PAGES`), chosen by the hash of the room and the cursor, and a page is kept in its place with the
## version, the state of the person, the room and the cursor. A page of another stamp is a miss and is written over, so
## a person who asks for every number overwrites only their own pages, and holds at most `cursor_slots` pages of each
## kind. Two cursors of one place take turns, and nothing worse happens.
##
## The sign-in filter reads the version of a read of a page that is kept (`cached?`, `watch`) before it looks the
## person up, and keeps it for the handler (`seen`), so a hit costs one read of the observer and none of the pool:
## the person of a session is kept for one version of the database too (`known_user`, `remember_user`; a hit does not
## touch the session, see `Auth.user_for`, so on a quiet database `last_active_at` can be older than its five-minute
## refresh; and it is refused once the session is older than the cookie life, which no commit announces), in a store of
## its own (`CAMPFIRE_SESSION_CACHE_MB`) so that the churn of pages cannot push a session out.
## A sign-out, a deactivation, a ban, a rename or a change of role is a commit, so the next read has a new version and
## looks the session up again. The person is looked up after the version was read, so what is kept under a version is
## that of the database at that version or later.
##
## Every page has a weak `ETag` (a digest of its bytes, as `Rack::ETag` writes it) and `Cache-Control: max-age=0,
## private, must-revalidate`, as Rails sends, and a request whose `If-None-Match` has the tag is a 304. The form of a
## room page carries a `client_message_id` drawn when the page is made, so two loads of one person at one version of the
## database share it; the app stores it and uses it for nothing else (a repeat is not dropped), so that costs nothing.

import Bond from "pkg/bond/bond"
import Cache from "std/cache"
import Auth from "../campfire/auth"
import Database from "../campfire/repo/database"
import Routes from "routes"

# What a megabyte of `CAMPFIRE_RESPONSE_CACHE_MB` is.
BYTES_PER_MB = 1024 * 1024

# `W/"` and 32 hex digits and `"`: the tag has this length always, so the cached text is the tag followed by the page.
ETAG_WIDTH = 36
ETAG_DIGITS = 32

# The kinds of page: the room page, the fragment of the older messages, the one of the messages after a message, the
# sidebar and the search.
export ROOM = "room"
export MESSAGES = "messages"
export AFTER = "after"
export SIDEBAR = "sidebar"
export SEARCH = "search"

# The content type that `Bond.html` sets, for a page answered as bytes.
HTML_TYPE = "text/html; charset=utf-8"

# Where the sign-in filter keeps the version of the database for the handler (`Bond.assign`).
VERSION_KEY = "database_version"

# The version that `watch` keeps when the observer failed: no real version is empty.
UNREADABLE = ""

# How much of the digest of the words of a search goes in the stamp of its page.
QUERY_DIGITS = 32

# How much of the digest of the name and the role of the person goes in the key.
SEEN_DIGITS = 16

CACHE_CONTROL = "max-age=0, private, must-revalidate"

# The version of the database that a request was made at, as it is assigned.
struct Version
  text: String
end

## The cache and the connection that watches the database for it.
export struct Pages
  store: Cache.Store
  people: Cache.Store
  search_slots: Int
  cursor_slots: Int
  observer: Database.Observer
end

## A page and its tag. The body is `Bytes`: the page is sent as bytes, and a cached page is cut out of the cached text
## by bytes (`unpack`), since `String.slice` walks every character of a text that has a non-ASCII one.
export struct Page
  etag: String
  body: Bytes
end

## Where a page of a request is kept: the cache and the key. A `stamp` that is not empty is what a page at a key that
## does not name its version is kept with (a search page or a page of older messages: the version, the state of the
## person and what the page was made for), and it must be the stamp of the page that is looked up.
export struct Spot
  pages: Pages
  key: String
  stamp: String
end

## The cache for `megabytes` of pages, `search_slots` search pages and `cursor_slots` pages of each kind of older
## messages for each person and `session_mb` megabytes for the people of the sessions, and its observer of the database
## at `url`, or `none` for 0 megabytes of pages, which turns it off. An `error` is an observer that does not open.
export def start(
  megabytes: Int,
  search_slots: Int,
  cursor_slots: Int,
  session_mb: Int,
  url: String,
) -> Result[Optional[Pages]]
  if megabytes <= 0
    return ok(none)
  end

  observer = try Database.open_observer(url)
  return ok(
    some(
      Pages(
        store: Cache.memory(megabytes * BYTES_PER_MB),
        people: Cache.memory(session_mb * BYTES_PER_MB),
        search_slots: search_slots,
        cursor_slots: cursor_slots,
        observer: observer,
      ),
    ),
  )
end

## Closes the observer of `pages`, if there are any.
export def stop(pages: Optional[Pages]) -> Void
  case pages
    none -> return
    some(found) -> Database.close_observer(found.observer)
  end
end

## Where the page of `kind` (`ROOM`, `MESSAGES` or `AFTER`) of `person` in the room `room_id` (`before` is the cursor of
## the kind) goes, as the database is now: read this before the page is made. `seen` is the version that the sign-in
## filter read (`seen`), `none` to read it now. `none` when there is no cache, the room is no number, the
## room page has a cursor (a person could fill the cache with a page for every number), or the version cannot be read
## (the page is then made and not kept). The name and the role of the person are in the key (or in the stamp, for the
## older messages, which are kept in one of the `cursor_slots` places of the person), so the pages of two states of one
## person are never mixed, whichever lookup gave the person.
export def spot(
  pages: Optional[Pages],
  seen: Optional[String],
  kind: String,
  person: Auth.User,
  room_id: Optional[Int],
  before: Optional[Int],
) -> Optional[Spot]
  if room_id.none? or (kind == ROOM and before.some?)
    return none
  end

  cursor = before.map do |id| id.to_s end.unwrap_or("")
  if kind == MESSAGES or kind == AFTER
    return cursor_spot(pages, seen, kind, person, room_id.unwrap!, cursor)
  end

  return located(pages, seen, kind, person, "#{room_id.unwrap!}:#{cursor}")
end

## Where the sidebar page of `person` goes (see `spot`).
export def sidebar_spot(pages: Optional[Pages], seen: Optional[String], person: Auth.User) -> Optional[Spot]
  return located(pages, seen, SIDEBAR, person, "")
end

## Where the search page of `person` for the words `query` goes (see `spot`): one of the `search_slots` places of the
## person, which the words choose, kept with the version, the state of the person, the words and `wanted`, the room of
## the `last_room` cookie: the page links back to a room that the cookie picks (`RoomsWeb.last_room_cookie`), which no
## commit changes, so the cookie is part of the stamp, as the words are.
export def search_spot(
  pages: Optional[Pages],
  seen: Optional[String],
  person: Auth.User,
  query: String,
  wanted: Optional[Int],
) -> Optional[Spot]
  case pages
    none -> return none
    some(found) ->
      version = version_of(found, seen)
      if not version.ok?
        return none
      end

      words = Digest.sha256_hexdigest(query.bytes).slice(0, QUERY_DIGITS)
      cookie = wanted.map do |id| id.to_s end.unwrap_or("")
      place = Digest.sha256(query.bytes)[0] % found.search_slots
      return some(
        Spot(
          pages: found,
          key: "page:#{SEARCH}:#{person.id}:#{place}",
          stamp: "#{version.unwrap!}:#{state_of(person)}:#{words}:#{cookie}",
        ),
      )
  end
end

## Whether the page at `path` is one that the cache keeps (a room page, the older messages, the sidebar, the search), so
## that the sign-in filter reads the version for it and for no other.
export def cached?(path: String) -> Bool
  if path == Routes.SIDEBAR or path == Routes.SEARCHES
    return true
  end

  parts = path.split("/")
  if parts.size < 3 or parts.size > 4 or not parts[0].empty? or parts[1] != "rooms"
    return false
  end

  id = parts[2].to_i
  return id.ok? and id.unwrap!.to_s == parts[2] and (parts.size == 3 or parts[3] == "messages")
end

## Reads the version of the database for a request and keeps it for the handler, which finds it with `seen`; `conn`
## as it is when there is no cache. The sign-in filter calls it before it looks the person up, so everything that the
## request then reads is at that version or later. A version that cannot be read is kept as unreadable, so that the
## handler does not read the observer again: nothing is kept for the request.
export def watch(conn: Bond.Conn, pages: Optional[Pages]) -> Bond.Conn
  case pages
    none -> return conn
    some(found) ->
      version = Database.version(found.observer)
      return Bond.assign(conn, VERSION_KEY, Version(text: version.unwrap_or(UNREADABLE)))
  end
end

## The version of the database now, for a reader that keeps what it reads under it (the checks of `/cable`: what is
## kept under a version is what the database held at that version or later, so a commit makes it a miss). `none` with
## no cache, or when the observer cannot read the version: such a reader reads the database.
export def current_version(pages: Optional[Pages]) -> Optional[String]
  case pages
    none -> return none
    some(found) ->
      version = Database.version(found.observer)
      if not version.ok? or version.unwrap!.empty?
        return none
      end

      return some(version.unwrap!)
  end
end

## The version that `watch` kept for the request, if it did (empty if the observer failed: the spots and the kept
## people take it as no version).
export def seen(conn: Bond.Conn) -> Optional[String]
  if not Bond.assigned?(conn, VERSION_KEY)
    return none
  end

  version = Bond.assigned(conn, VERSION_KEY, Version.codec)
  if not version.ok?
    return none
  end

  return some(version.unwrap!.text)
end

## The person of the session with `token`, if the database is at the version that `watch` read, the person was kept at
## it (`remember_user`) and the session has not ended since.
export def known_user(pages: Optional[Pages], seen: Optional[String], token: String) -> Optional[Auth.User]
  case pages
    none -> return none
    some(found) -> return recalled(found, seen, token)
  end
end

## Keeps the session with `token` for the version `seen`. A session that is ended, or a person who is deactivated,
## banned, renamed or changed, is a commit, so it is another version; a session that grows too old is not (no one has to
## commit), so the time it ends at is kept with the person, and `known_user` refuses the person after it.
export def remember_user(pages: Optional[Pages], seen: Optional[String], token: String, session: Auth.Session) -> Void
  case pages
    none -> return
    some(found) ->
      case seen
        none -> return
        some(version) if not version.empty? ->
          Cache.put(found.people, user_key(version, token), Auth.Session.codec.encode(session))
        _ -> return
      end
  end
end

## The page that is kept at `spot`, if there is one.
export def lookup(spot: Optional[Spot]) -> Optional[Page]
  case spot
    none -> return none
    some(found) -> return unpack(found, Cache.get(found.pages.store, found.key))
  end
end

## The page for `html`, with its tag, kept at `spot` when there is one.
export def keep(spot: Optional[Spot], html: String) -> Page
  digest = Digest.sha256_hexdigest(html.bytes).slice(0, ETAG_DIGITS)
  etag = "W/\"#{digest}\""
  case spot
    none -> return Page(etag: etag, body: html.bytes)
    some(found) -> Cache.put(found.pages.store, found.key, stamped(found) + etag + html)
  end

  return Page(etag: etag, body: html.bytes)
end

## The answer for `page`: a 304 when `If-None-Match` of the request names its tag, else a 200 with the page.
export def respond(conn: Bond.Conn, page: Page) -> Bond.Conn
  if matches?(conn, page.etag)
    return tagged(Bond.status(conn, 304), page)
  end

  return tagged(Bond.header(Bond.bytes(conn, 200, page.body), "content-type", HTML_TYPE), page)
end

# The place of the older messages of `kind` that the hash of the room and the cursor chooses among the `cursor_slots`
# of the person, kept with the version, the state of the person, the room and the cursor.
def cursor_spot(
  pages: Optional[Pages],
  seen: Optional[String],
  kind: String,
  person: Auth.User,
  room_id: Int,
  cursor: String,
) -> Optional[Spot]
  case pages
    none -> return none
    some(found) ->
      version = version_of(found, seen)
      if not version.ok?
        return none
      end

      scope = "#{room_id}:#{cursor}"
      place = Digest.sha256(scope.bytes)[0] % found.cursor_slots
      return some(
        Spot(
          pages: found,
          key: "page:#{kind}:#{person.id}:#{place}",
          stamp: "#{version.unwrap!}:#{state_of(person)}:#{scope}",
        ),
      )
  end
end

def located(
  pages: Optional[Pages],
  seen: Optional[String],
  kind: String,
  person: Auth.User,
  scope: String,
) -> Optional[Spot]
  case pages
    none -> return none
    some(found) ->
      version = version_of(found, seen)
      if not version.ok?
        return none
      end

      key = "page:#{version.unwrap!}:#{kind}:#{person.id}:#{state_of(person)}:#{scope}"
      return some(Spot(pages: found, key: key, stamp: ""))
  end
end

# A digest of the name and the role of the person: two states of one person do not share a page.
def state_of(person: Auth.User) -> String
  return Digest.sha256_hexdigest("#{person.role}\n#{person.name}".bytes).slice(0, SEEN_DIGITS)
end

# What goes before the tag in the cached text: the stamp and a line break, or nothing.
def stamped(spot: Spot) -> String
  if spot.stamp.empty?
    return ""
  end

  return spot.stamp + "\n"
end

def version_of(pages: Pages, seen: Optional[String]) -> Result[String]
  case seen
    some(version) if version.empty? -> return error("database error: the version could not be read")
    some(version) -> return ok(version)
    none -> return Database.version(pages.observer)
  end
end

def recalled(pages: Pages, seen: Optional[String], token: String) -> Optional[Auth.User]
  case seen
    none -> return none
    some(version) if version.empty? -> return none
    some(version) ->
      kept = Cache.get(pages.people, user_key(version, token))
      if kept.none?
        return none
      end

      session = Auth.Session.codec.decode(kept.unwrap!)
      if not session.ok? or session.unwrap!.ends_at_ms <= Time.now_ms()
        return none
      end

      return some(session.unwrap!.user)
  end
end

def user_key(version: String, token: String) -> String
  return "user:#{version}:#{token}"
end

# The page in the cached text `kept` at `spot`, or `none` when there is none or it was kept with another stamp. The
# tag is
# a short slice, but the body is taken by bytes: `String.slice` to the end of a text with a non-ASCII character costs a
# walk over all of it. The tag is ASCII, so it follows the stamp at `prefix.length` characters and `prefix.bytesize`
# bytes.
def unpack(spot: Spot, kept: Optional[String]) -> Optional[Page]
  case kept
    none -> return none
    some(text) ->
      prefix = stamped(spot)
      if not prefix.empty? and not text.start_with?(prefix)
        return none
      end

      etag = text.slice(prefix.length, ETAG_WIDTH)
      return some(Page(etag: etag, body: text.bytes.drop(prefix.bytesize + ETAG_WIDTH)))
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

import Cache from "std/cache"
import HTTP from "std/http"
import Bond from "pkg/bond/bond"
import Testing from "pkg/bond/testing"
import Db from "pkg/db/db"
import Auth from "../src/campfire/auth"
import Database from "../src/campfire/repo/database"
import PageCache from "../src/campfire_web/page_cache"

SLOTS = 8
READERS = 6
READS = 2_000
COMMITS = 50
HOUR_MS = 3_600_000
PAGE = "é<p>café 日本</p>"

def ana() -> Auth.User
  return Auth.User(id: 1, name: "Ana", role: "member")
end

# The body of a kept page as text; the bodies of the tests hold non-ASCII text, which `unpack` must cut out by bytes.
def text_of(body: Bytes) -> String
  return body.decode("utf-8").unwrap!
end

# The session of `person` that ends `ms` from now.
def lasting(person: Auth.User, ms: Int) -> Auth.Session
  return Auth.Session(user: person, ends_at_ms: Time.now_ms() + ms)
end

# `pages` for a database that was made and has one table, and a connection of its own to write with.
def with_database(dir: String, body: Fn[Database.Observer, Db.Connection, String, Result[Void]]) -> Result[Void]
  url = "sqlite:#{dir}/pages.db"
  writer = try Db.open(url)
  try Db.execute(writer, "create table notes (id integer primary key, body text)", [])
  observer = try Database.open_observer(url)
  outcome = body.call(observer, writer, url)
  Database.close_observer(observer)
  Db.close(writer)
  return outcome
end

def version_follows_commits(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  _ = url
  first = try Database.version(observer)
  try Test.eq(try Database.version(observer), first)
  try Db.execute(writer, "insert into notes (body) values ('x')", [])
  second = try Database.version(observer)
  try Test.assert(second != first, "a commit by another connection left the version as it was")
  return ok()
end

# Reads the version `READS` times and checks that it never goes back.
def read_often(observer: Database.Observer) -> Result[Int]
  last = -1
  for _ in 1..READS
    now = (try Database.version(observer)).to_i!
    try Test.assert(now >= last, "the version went back from #{last} to #{now}")
    last = now
  end

  return ok(last)
end

# Several tasks read at once while this one commits: every read answers, none goes back, and a read after a commit
# always sees it, even when other readers are in the middle of theirs.
def readers_share_the_connection(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  _ = url
  readers = (1..READERS).to_a.map do |_| Task.spawn do read_often(observer) end end
  seen = try Database.version(observer)
  for i in 1..COMMITS
    try Db.execute(writer, "insert into notes (body) values ('x')", [])
    now = try Database.version(observer)
    try Test.assert(now != seen, "a commit number #{i} was not seen by the read that followed it")
    seen = now
  end

  for reader in readers
    try Task.await(reader)
  end

  return ok()
end

# A holder that has the turn and does not give it back (here the test itself) makes a reader time out into an error,
# and the timeout does not make a second token, which would let two readers share the statement.
def a_stalled_holder_makes_no_second_token(
  observer: Database.Observer,
  writer: Db.Connection,
  url: String,
) -> Result[Void]
  _ = writer
  _ = url
  try observer.turn.recv(0)
  try Test.error?(Database.version(observer))
  try Test.assert(not observer.turn.recv(0).ok?, "a reader that timed out put a token back")
  try observer.turn.send(true, 0)
  return Test.assert(Database.version(observer).ok?, "no version once the holder gave the turn back")
end

def read_until_closed(observer: Database.Observer) -> Result[Void]
  for _ in 1..READS
    _ = Database.version(observer)
  end

  return ok()
end

# A close while readers are at work: each read answers or is refused, none hangs or stops a task, and a read after
# the close is refused at once (it does not wait for the turn).
def close_with_readers_waiting(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  _ = writer
  _ = url
  readers = (1..READERS).to_a.map do |_| Task.spawn do read_until_closed(observer) end end
  Task.sleep(2)
  Database.close_observer(observer)
  for reader in readers
    try Task.await(reader)
  end

  started = Time.now_ms()
  try Test.error?(Database.version(observer))
  return Test.assert(Time.now_ms() - started < 500, "a read after the close waited for the turn")
end

def refuses_urls_that_cannot_be_watched() -> Result[Void]
  for url in ["sqlite:", "sqlite://app.db", "sqlite::memory:", "postgres://localhost/app", "app.db"]
    try Test.error?(Database.open_observer(url))
  end

  return ok()
end

def spots_follow_the_person(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  _ = writer
  _ = url
  pages = some(
    PageCache.Pages(
      store: Cache.memory(1_000_000),
      people: Cache.memory(100_000),
      search_slots: SLOTS,
      cursor_slots: SLOTS,
      observer: observer,
    ),
  )

  here = PageCache.spot(pages, none, PageCache.ROOM, ana(), some(1), none)
  try Test.assert(here.some?, "no spot for a room page")
  again = PageCache.spot(pages, none, PageCache.ROOM, ana(), some(1), none)
  try Test.eq(again.unwrap!.key, here.unwrap!.key)
  # What the sign-in filter read about the person is in the key, so a stale name or role is not kept under a
  # new version.
  renamed = PageCache.spot(pages, none, PageCache.ROOM, ana().with(name: "Anna"), some(1), none)
  try Test.assert(renamed.unwrap!.key != here.unwrap!.key, "a rename left the key as it was")
  demoted = PageCache.spot(pages, none, PageCache.ROOM, ana().with(role: "administrator"), some(1), none)
  try Test.assert(demoted.unwrap!.key != here.unwrap!.key, "a change of role left the key as it was")
  # One person must not fill the cache with a page for every number, and an unknown room is not kept.
  try Test.assert(
    PageCache.spot(pages, none, PageCache.ROOM, ana(), some(1), some(5)).none?,
    "a room page with a cursor",
  )

  try Test.assert(PageCache.spot(pages, none, PageCache.ROOM, ana(), none, none).none?, "a room that is no number")
  older = PageCache.spot(pages, none, PageCache.MESSAGES, ana(), some(1), some(5))
  return Test.assert(older.some?, "no spot for older messages")
end

# The sidebar and the search are kept for their person (and the words), and the person of a session for one version.
def sidebar_search_and_person_are_kept(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  _ = url
  pages = some(
    PageCache.Pages(
      store: Cache.memory(1_000_000),
      people: Cache.memory(100_000),
      search_slots: SLOTS,
      cursor_slots: SLOTS,
      observer: observer,
    ),
  )

  seen = some(try Database.version(observer))
  sidebar = PageCache.sidebar_spot(pages, seen, ana())
  try Test.assert(PageCache.lookup(sidebar).none?, "a sidebar before it is kept")
  made = PageCache.keep(sidebar, "é<p>rooms é</p>")
  kept = PageCache.lookup(sidebar)
  try Test.eq(text_of(kept.unwrap!.body), "é<p>rooms é</p>")
  try Test.eq(kept.unwrap!.etag, made.etag)
  bea = ana().with(id: 2, name: "Bea")
  try Test.assert(PageCache.lookup(PageCache.sidebar_spot(pages, seen, bea)).none?, "a sidebar of another person")
  coffee = PageCache.search_spot(pages, seen, ana(), "coffee", none)
  tea = PageCache.search_spot(pages, seen, ana(), "tea", none)
  try Test.assert(coffee.unwrap!.key != tea.unwrap!.key, "two queries share a key")
  try Test.assert(coffee.unwrap!.key != sidebar.unwrap!.key, "a search and a sidebar share a key")
  PageCache.remember_user(pages, seen, "token", lasting(ana(), HOUR_MS))
  try Test.eq(PageCache.known_user(pages, seen, "token").unwrap!.name, "Ana")
  # No commit announces that a session grew too old, so the person is refused once the session has ended.
  PageCache.remember_user(pages, seen, "ended", lasting(ana(), -HOUR_MS))
  try Test.assert(PageCache.known_user(pages, seen, "ended").none?, "a person past the end of the session")
  try Test.assert(PageCache.known_user(pages, seen, "other").none?, "a person for another token")
  try Test.assert(PageCache.known_user(pages, none, "token").none?, "a person without a version")
  # A version that the filter could not read is kept as empty: nothing is kept or found under it, and the observer is
  # not asked again.
  try Test.assert(PageCache.known_user(pages, some(""), "token").none?, "a person under an unreadable version")
  PageCache.remember_user(pages, some(""), "ghost", lasting(ana(), HOUR_MS))
  try Test.assert(PageCache.known_user(pages, seen, "ghost").none?, "a person kept under an unreadable version")
  try Test.assert(PageCache.known_user(pages, some(""), "ghost").none?, "a person found under an unreadable version")
  try Test.assert(PageCache.sidebar_spot(pages, some(""), ana()).none?, "a sidebar under an unreadable version")
  try Test.assert(
    PageCache.search_spot(pages, some(""), ana(), "tea", none).none?,
    "a search under an unreadable version",
  )

  try Db.execute(writer, "insert into notes (body) values ('x')", [])
  later = some(try Database.version(observer))
  try Test.assert(PageCache.known_user(pages, later, "token").none?, "a person kept across a commit")
  return Test.assert(PageCache.lookup(PageCache.sidebar_spot(pages, later, ana())).none?, "a sidebar across a commit")
end

# The session that `Auth.user_for` reads from a row is kept as it is and found again. Its end is in Unix ms, which
# guards the `* 1000` of the query (it once multiplied only the seconds of the cookie life), and is `SESSION_SECONDS`
# after the row was made.
def fresh_session_is_kept_and_found(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  _ = try Database.migrate(url)
  stamp = "'2026-03-01 09:00:00.000000'"
  try Db.execute(
    writer,
    "insert into users (name, email_address, password_digest, role, created_at, updated_at) " +
    "values ('Ana', 'ana@example.com', 'x', 1, #{stamp}, #{stamp})",
    [],
  )

  opened = try Auth.open_session(writer, 1, "", "")
  token = opened.unwrap_or("")
  try Test.assert(not token.empty?, "no session was opened")
  found = try Auth.user_for(writer, token)
  try Test.assert(found.some?, "a fresh session was refused")
  session = found.unwrap!
  expected = Time.now_ms() + Auth.SESSION_SECONDS * 1000
  try Test.assert((session.ends_at_ms - expected).abs < 10_000, "the end of the session is not 30 days from now")
  pages = some(
    PageCache.Pages(
      store: Cache.memory(1_000_000),
      people: Cache.memory(100_000),
      search_slots: SLOTS,
      cursor_slots: SLOTS,
      observer: observer,
    ),
  )

  seen = some(try Database.version(observer))
  PageCache.remember_user(pages, seen, token, session)
  return Test.eq(PageCache.known_user(pages, seen, token).unwrap!.name, "Ana")
end

# A person has `search_slots` places for search pages whatever they type: the pages of more queries write over each
# other, the page of another person stays, and a page is only found for the words, the version and the person it was
# made for.
def searches_are_bounded_per_person(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  _ = writer
  _ = url
  pages = some(
    PageCache.Pages(
      store: Cache.memory(1_000_000),
      people: Cache.memory(100_000),
      search_slots: SLOTS,
      cursor_slots: SLOTS,
      observer: observer,
    ),
  )

  seen = some(try Database.version(observer))
  bea = ana().with(id: 2, name: "Bea")
  PageCache.keep(PageCache.search_spot(pages, seen, bea, "coffee", none), "<p>Bea</p>")
  queries: List[String] = []
  for n in 0...60
    queries = queries.push("words#{n}")
  end

  for query in queries
    PageCache.keep(PageCache.search_spot(pages, seen, ana(), query, none), "<p>#{query}</p>")
  end

  held = queries.select do |query| PageCache.lookup(PageCache.search_spot(pages, seen, ana(), query, none)).some? end
  try Test.assert(held.size <= SLOTS, "a person holds more search pages than they have places")
  try Test.assert(held.size > 0, "no search page is kept")
  other = PageCache.lookup(PageCache.search_spot(pages, seen, bea, "coffee", none))
  try Test.eq(text_of(other.unwrap!.body), "<p>Bea</p>")
  last = queries.last
  try Test.eq(
    text_of(PageCache.lookup(PageCache.search_spot(pages, seen, ana(), last, none)).unwrap!.body),
    "<p>#{last}</p>",
  )

  try Test.assert(
    PageCache.lookup(PageCache.search_spot(pages, seen, ana().with(name: "Anna"), last, none)).none?,
    "a search page of another state of the person",
  )

  try Test.assert(
    PageCache.lookup(PageCache.search_spot(pages, seen, ana(), last, some(2))).none?,
    "a search page for another last room",
  )

  return Test.assert(
    PageCache.lookup(PageCache.search_spot(pages, some("0:other"), ana(), last, none)).none?,
    "a search page of another version",
  )
end

# A person has `cursor_slots` places for each kind of older messages whatever cursors they ask for: more cursors write
# over each other, the pages of another person stay, and a page is only found for the version,
# the person, the room and the cursor it was made for.
def cursor_pages_are_bounded_per_person(
  observer: Database.Observer,
  writer: Db.Connection,
  url: String,
) -> Result[Void]
  _ = writer
  _ = url
  pages = some(
    PageCache.Pages(
      store: Cache.memory(1_000_000),
      people: Cache.memory(100_000),
      search_slots: SLOTS,
      cursor_slots: SLOTS,
      observer: observer,
    ),
  )

  seen = some(try Database.version(observer))
  bea = ana().with(id: 2, name: "Bea")
  PageCache.keep(PageCache.spot(pages, seen, PageCache.MESSAGES, bea, some(1), some(7)), "<p>Bea before</p>")
  PageCache.keep(PageCache.spot(pages, seen, PageCache.AFTER, bea, some(1), some(7)), "<p>Bea after</p>")
  cursors = (1...61).to_a
  for cursor in cursors
    spot = PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(cursor))
    PageCache.keep(spot, "<p>#{cursor}</p>")
  end

  for cursor in cursors
    spot = PageCache.spot(pages, seen, PageCache.AFTER, ana(), some(1), some(cursor + 100))
    PageCache.keep(spot, "<p>after #{cursor}</p>")
  end

  held = cursors.select do |cursor|
    PageCache.lookup(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(cursor))).some?
  end

  held_after = cursors.select do |cursor|
    PageCache.lookup(PageCache.spot(pages, seen, PageCache.AFTER, ana(), some(1), some(cursor + 100))).some?
  end

  try Test.assert(held.size <= SLOTS, "a person holds more pages before a cursor than they have places")
  try Test.assert(held.size > 0, "no page before a cursor is kept")
  try Test.assert(held_after.size <= SLOTS, "a person holds more pages after a cursor than they have places")
  try Test.assert(held_after.size > 0, "no page after a cursor is kept")
  other = PageCache.lookup(PageCache.spot(pages, seen, PageCache.MESSAGES, bea, some(1), some(7)))
  try Test.eq(text_of(other.unwrap!.body), "<p>Bea before</p>")
  after = PageCache.lookup(PageCache.spot(pages, seen, PageCache.AFTER, bea, some(1), some(7)))
  return Test.eq(text_of(after.unwrap!.body), "<p>Bea after</p>")
end

# A page in a place of the person is a miss for any other stamp (the version, the state of the person, the room, the
# cursor), and the page that is kept then writes over it.
def cursor_stamp_mismatch_is_a_miss(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  _ = writer
  _ = url
  pages = some(
    PageCache.Pages(
      store: Cache.memory(1_000_000),
      people: Cache.memory(100_000),
      search_slots: SLOTS,
      cursor_slots: 1,
      observer: observer,
    ),
  )

  seen = some(try Database.version(observer))
  PageCache.keep(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(5)), "<p>fivé</p>")
  found = PageCache.lookup(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(5)))
  try Test.eq(text_of(found.unwrap!.body), "<p>fivé</p>")
  # A body that starts with multi-byte characters is cut right after the stamp and the tag, and so is an empty one.
  PageCache.keep(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(5)), "日本🔥é")
  wide = PageCache.lookup(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(5)))
  try Test.eq(text_of(wide.unwrap!.body), "日本🔥é")
  PageCache.keep(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(5)), "")
  empty = PageCache.lookup(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(5)))
  try Test.assert(empty.unwrap!.body.empty?, "an empty page is kept empty")
  PageCache.keep(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(5)), "<p>fivé</p>")
  # With one place all the cursors share it, so these differ in the stamp alone.
  try Test.assert(
    PageCache.lookup(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(6))).none?,
    "a page of another cursor",
  )

  try Test.assert(
    PageCache.lookup(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(2), some(5))).none?,
    "a page of another room",
  )

  try Test.assert(
    PageCache.lookup(
      PageCache.spot(pages, seen, PageCache.MESSAGES, ana().with(name: "Anna"), some(1), some(5)),
    ).none?,
    "a page of another state of the person",
  )

  try Test.assert(
    PageCache.lookup(
      PageCache.spot(pages, seen, PageCache.MESSAGES, ana().with(role: "administrator"), some(1), some(5)),
    ).none?,
    "a page of another role of the person",
  )

  try Test.assert(
    PageCache.lookup(PageCache.spot(pages, some("0:other"), PageCache.MESSAGES, ana(), some(1), some(5))).none?,
    "a page of another version",
  )

  PageCache.keep(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(6)), "<p>six</p>")
  try Test.assert(
    PageCache.lookup(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(5))).none?,
    "a page that was written over",
  )

  six = PageCache.lookup(PageCache.spot(pages, seen, PageCache.MESSAGES, ana(), some(1), some(6)))
  return Test.eq(text_of(six.unwrap!.body), "<p>six</p>")
end

# Only the pages that the cache keeps make the sign-in filter read the version.
def cached_paths() -> Result[Void]
  for path in ["/users/me/sidebar", "/searches", "/rooms/12", "/rooms/12/messages", "/users/TOKEN/avatar"]
    try Test.assert(PageCache.cached?(path), "#{path} is kept")
  end

  for path in [
    "/rooms/new", "/rooms/12/edit", "/rooms/12/@5", "/rooms/12/messages/3", "/users//avatar", "/users/1/avatar/x",
    "/cable", "/",
  ]
    try Test.assert(not PageCache.cached?(path), "#{path} is not kept")
  end

  return ok()
end

# A version that cannot be read (the observer is closed or lost) makes no spot: the page is made and nothing is kept.
def failing_observer_keeps_nothing(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  _ = writer
  _ = url
  store = Cache.memory(1_000_000)
  pages = some(
    PageCache.Pages(
      store: store,
      people: Cache.memory(100_000),
      search_slots: SLOTS,
      cursor_slots: SLOTS,
      observer: observer,
    ),
  )

  Database.close_observer(observer)
  spot = PageCache.spot(pages, none, PageCache.ROOM, ana(), some(1), none)
  try Test.assert(spot.none?, "a spot from an observer that is closed")
  try Test.assert(PageCache.lookup(spot).none?, "a page without a spot")
  page = PageCache.keep(spot, "<p>made</p>")
  try Test.eq(text_of(page.body), "<p>made</p>")
  return Test.eq(Cache.bytes(store), 0)
end

def sent_page(conn: Bond.Conn) -> Result[Bond.Conn]
  return ok(PageCache.respond(conn, PageCache.keep(none, PAGE)))
end

# What the page cache sent before the body was `Bytes`: `Bond.html` and the two headers.
def html_page(conn: Bond.Conn) -> Result[Bond.Conn]
  tag = PageCache.keep(none, PAGE).etag
  html = Bond.html(conn, 200, PAGE)
  return ok(Bond.header(Bond.header(html, "etag", tag), "cache-control", "max-age=0, private, must-revalidate"))
end

# `respond` answers with the status, headers and bytes of `Bond.html`, and a 304 without a body for the tag it sent.
def respond_matches_html() -> Result[Void]
  app = (
    Bond.app()
    |> Bond.get("/sent", &sent_page)
    |> Bond.get("/html", &html_page)
  )

  sent = Testing.request(app, "GET", "/sent")
  html = Testing.request(app, "GET", "/html")
  try Test.eq(sent.status, 200)
  try Test.eq(sent.headers, html.headers)
  try Test.eq(sent.body, html.body)
  try Test.eq(sent.body, PAGE.bytes)
  try Test.eq(HTTP.header_values(sent.headers, "content-type"), ["text/html; charset=utf-8"])
  tag = HTTP.header_values(sent.headers, "etag")[0]
  same = Testing.request(app, "GET", "/sent", [Header(name: "if-none-match", value: tag)])
  try Test.eq(same.status, 304)
  try Test.assert(same.body.empty?, "a 304 has no body")
  return Test.eq(HTTP.header_values(same.headers, "etag"), [tag])
end

def run_in_dir(body: Fn[Database.Observer, Db.Connection, String, Result[Void]]) -> Result[Void]
  root = System.env("TMPDIR").unwrap_or("/tmp")
  dir = try Path.join([root, "campfire-pages-#{OpenSSL.Random.hex(8)}"])
  try Dir.mkdir_private(dir)
  outcome = with_database(dir, body)
  removed = Path.remove(dir)
  try outcome
  return removed
end

def main() -> Void
  Test.run([
    Test.test("the version changes with a commit of another connection") do run_in_dir(&version_follows_commits) end,
    Test.test("tasks that read the version at once all get an answer, and a read after a commit sees the commit") do
      run_in_dir(&readers_share_the_connection)
    end,
    Test.test("a reader that times out for a stalled holder makes no second token") do
      run_in_dir(&a_stalled_holder_makes_no_second_token)
    end,
    Test.test("a close while readers are at work leaves no reader stuck and refuses the reads after it") do
      run_in_dir(&close_with_readers_waiting)
    end,
    Test.test(
      "an observer is refused for a url that is empty, has // or is in memory, and for one that is not sqlite",
    ) do refuses_urls_that_cannot_be_watched() end,
    Test.test(
      "a spot has the person's name and role, and the room page with a cursor and an unknown room have none",
    ) do run_in_dir(&spots_follow_the_person) end,
    Test.test("the sidebar, the search and the person of a session are kept for their version") do
      run_in_dir(&sidebar_search_and_person_are_kept)
    end,
    Test.test("the session that user_for reads from a row is kept and found, and ends 30 days after it began") do
      run_in_dir(&fresh_session_is_kept_and_found)
    end,
    Test.test("a person keeps a bounded number of search pages, each for its words, version and person") do
      run_in_dir(&searches_are_bounded_per_person)
    end,
    Test.test(
      "a person keeps a bounded number of pages of older messages for each kind, and another person keeps theirs",
    ) do run_in_dir(&cursor_pages_are_bounded_per_person) end,
    Test.test("a page of older messages with another stamp is a miss that the next page writes over") do
      run_in_dir(&cursor_stamp_mismatch_is_a_miss)
    end,
    Test.test("only a room page, the older messages, the sidebar and the search are read at their version") do
      cached_paths()
    end,
    Test.test(
      "a page is answered with the status, headers and bytes of Bond.html, and a repeat of its tag is a 304",
    ) do respond_matches_html() end,
    Test.test("an observer that fails gives no spot, so the page is made and nothing is kept") do
      run_in_dir(&failing_observer_keeps_nothing)
    end,
  ])
end

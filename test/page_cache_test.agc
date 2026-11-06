import Cache from "std/cache"
import Db from "pkg/db/db"
import Auth from "../src/campfire/auth"
import Database from "../src/campfire/repo/database"
import PageCache from "../src/campfire_web/page_cache"

CHECKOUT_MS = 1_000
SLOTS = 8

def ana() -> Auth.User
  return Auth.User(id: 1, name: "Ana", role: "member")
end

# The text after the last `:` of a version, which is the random epoch of the connection that read it.
def epoch_of(version: String) -> String
  return version.split(":").last
end

# `pages` for a database that was made and has one table, and a connection of its own to write with.
def with_database(dir: String, body: Fn[Database.Observer, Db.Connection, String, Result[Void]]) -> Result[Void]
  url = "sqlite:#{dir}/pages.db"
  writer = try Db.open(url)
  try Db.execute(writer, "create table notes (id integer primary key, body text)", [])
  observer = try Database.open_observer(url, CHECKOUT_MS)
  outcome = body.call(observer, writer, url)
  Database.close_observer(observer)
  Db.close(writer)
  return outcome
end

def version_follows_commits(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  first = try Database.version(observer)
  try Test.eq(try Database.version(observer), first)
  try Db.execute(writer, "insert into notes (body) values ('x')", [])
  second = try Database.version(observer)
  try Test.assert(second != first, "a commit by another connection left the version as it was")
  try Test.eq(epoch_of(second), epoch_of(first))
  # A connection that replaces the observer has a new epoch, so it cannot count its way back to a version that an
  # old page was kept under.
  other = try Database.open_observer(url, CHECKOUT_MS)
  replaced = try Database.version(other)
  Database.close_observer(other)
  return Test.assert(epoch_of(replaced) != epoch_of(second), "two connections share an epoch")
end

def spots_follow_the_person(observer: Database.Observer, writer: Db.Connection, url: String) -> Result[Void]
  _ = writer
  _ = url
  pages = some(
    PageCache.Pages(
      store: Cache.memory(1_000_000),
      people: Cache.memory(100_000),
      search_slots: SLOTS,
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
      observer: observer,
    ),
  )

  seen = some(try Database.version(observer))
  sidebar = PageCache.sidebar_spot(pages, seen, ana())
  try Test.assert(PageCache.lookup(sidebar).none?, "a sidebar before it is kept")
  made = PageCache.keep(sidebar, "<p>rooms</p>")
  kept = PageCache.lookup(sidebar)
  try Test.eq(kept.unwrap!.body, "<p>rooms</p>")
  try Test.eq(kept.unwrap!.etag, made.etag)
  bea = ana().with(id: 2, name: "Bea")
  try Test.assert(PageCache.lookup(PageCache.sidebar_spot(pages, seen, bea)).none?, "a sidebar of another person")
  coffee = PageCache.search_spot(pages, seen, ana(), "coffee")
  tea = PageCache.search_spot(pages, seen, ana(), "tea")
  try Test.assert(coffee.unwrap!.key != tea.unwrap!.key, "two queries share a key")
  try Test.assert(coffee.unwrap!.key != sidebar.unwrap!.key, "a search and a sidebar share a key")
  PageCache.remember_user(pages, seen, "token", ana())
  try Test.eq(PageCache.known_user(pages, seen, "token").unwrap!.name, "Ana")
  try Test.assert(PageCache.known_user(pages, seen, "other").none?, "a person for another token")
  try Test.assert(PageCache.known_user(pages, none, "token").none?, "a person without a version")
  try Db.execute(writer, "insert into notes (body) values ('x')", [])
  later = some(try Database.version(observer))
  try Test.assert(PageCache.known_user(pages, later, "token").none?, "a person kept across a commit")
  return Test.assert(PageCache.lookup(PageCache.sidebar_spot(pages, later, ana())).none?, "a sidebar across a commit")
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
      observer: observer,
    ),
  )

  seen = some(try Database.version(observer))
  bea = ana().with(id: 2, name: "Bea")
  PageCache.keep(PageCache.search_spot(pages, seen, bea, "coffee"), "<p>Bea</p>")
  queries: List[String] = []
  for n in 0...60
    queries = queries.push("words#{n}")
  end

  for query in queries
    PageCache.keep(PageCache.search_spot(pages, seen, ana(), query), "<p>#{query}</p>")
  end

  held = queries.select do |query| PageCache.lookup(PageCache.search_spot(pages, seen, ana(), query)).some? end
  try Test.assert(held.size <= SLOTS, "a person holds more search pages than they have places")
  try Test.assert(held.size > 0, "no search page is kept")
  other = PageCache.lookup(PageCache.search_spot(pages, seen, bea, "coffee"))
  try Test.eq(other.unwrap!.body, "<p>Bea</p>")
  last = queries.last
  try Test.eq(PageCache.lookup(PageCache.search_spot(pages, seen, ana(), last)).unwrap!.body, "<p>#{last}</p>")
  try Test.assert(
    PageCache.lookup(PageCache.search_spot(pages, seen, ana().with(name: "Anna"), last)).none?,
    "a search page of another state of the person",
  )

  return Test.assert(
    PageCache.lookup(PageCache.search_spot(pages, some("0:other"), ana(), last)).none?,
    "a search page of another version",
  )
end

# Only the pages that the cache keeps make the sign-in filter read the version.
def cached_paths() -> Result[Void]
  for path in ["/users/me/sidebar", "/searches", "/rooms/12", "/rooms/12/messages"]
    try Test.assert(PageCache.cached?(path), "#{path} is kept")
  end

  for path in [
    "/rooms/new", "/rooms/12/edit", "/rooms/12/@5", "/rooms/12/messages/3", "/users/1/avatar", "/cable", "/",
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
  pages = some(PageCache.Pages(store: store, people: Cache.memory(100_000), search_slots: SLOTS, observer: observer))
  Database.close_observer(observer)
  spot = PageCache.spot(pages, none, PageCache.ROOM, ana(), some(1), none)
  try Test.assert(spot.none?, "a spot from an observer that is closed")
  try Test.assert(PageCache.lookup(spot).none?, "a page without a spot")
  page = PageCache.keep(spot, "<p>made</p>")
  try Test.eq(page.body, "<p>made</p>")
  return Test.eq(Cache.bytes(store), 0)
end

def run_in_dir(body: Fn[Database.Observer, Db.Connection, String, Result[Void]]) -> Result[Void]
  root = System.env("TMPDIR").unwrap_or("/tmp")
  dir = try Path.join([root, "campfire-pages-#{SecureRandom.hex(8)}"])
  try Dir.mkdir_private(dir)
  outcome = with_database(dir, body)
  removed = Path.remove(dir)
  try outcome
  return removed
end

def main() -> Void
  Test.run([
    Test.test("the version changes with a commit of another connection and a new connection has a new epoch") do
      run_in_dir(&version_follows_commits)
    end,
    Test.test(
      "a spot has the person's name and role, and the room page with a cursor and an unknown room have none",
    ) do run_in_dir(&spots_follow_the_person) end,
    Test.test("the sidebar, the search and the person of a session are kept for their version") do
      run_in_dir(&sidebar_search_and_person_are_kept)
    end,
    Test.test("a person keeps a bounded number of search pages, each for its words, version and person") do
      run_in_dir(&searches_are_bounded_per_person)
    end,
    Test.test("only a room page, the older messages, the sidebar and the search are read at their version") do
      cached_paths()
    end,
    Test.test("an observer that fails gives no spot, so the page is made and nothing is kept") do
      run_in_dir(&failing_observer_keeps_nothing)
    end,
  ])
end

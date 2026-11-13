## The search of messages: `GET /searches?q=words` shows the messages of the person's rooms that match, `POST
## /searches` remembers what they searched for (the form of the page posts it) and goes to the results, and `DELETE
## /searches/clear` forgets all of them. The page links back to the room that the person was in last. What a person
## types is words (`Searches.words`), never a search expression, so no query can make the index fail. The results are
## read on the same connection as the sidebar, and a page has no message of a room that the person is not in.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import Blocks from "blocks"
import Database from "../campfire/repo/database"
import PageCache from "page_cache"
import Rooms from "../campfire/rooms"
import RoomsWeb from "rooms"
import Routes from "routes"
import Searches from "../campfire/searches"
import Views from "views"

## Adds the routes of the search to `app`. They are not in `AuthWeb.PUBLIC_PATHS`, so they need a sign-in. The results
## are kept whole in `pages` for one person, one query, one version of the database and one `last_room` cookie
## (`PageCache`); a clear is a commit, so the next page has none of the searches that it took away.
def add(app: Bond.App, pool: Database.Pool, pages: Optional[PageCache.Pages]) -> Bond.App
  on_get_searches = Blocks.handler do |conn| show(conn, pool, pages) end
  on_post_searches = Blocks.handler do |conn| remember(conn, pool) end
  on_post_searches_clear = Blocks.handler do |conn| post_clear(conn, pool) end

  (
    app
    |> Bond.get(Routes.SEARCHES, on_get_searches)
    |> Bond.post(Routes.SEARCHES, on_post_searches)
    |> Bond.post(Routes.SEARCHES_CLEAR, on_post_searches_clear)
    |> Bond.delete(Routes.SEARCHES_CLEAR) do |conn| clear(conn, pool) end
  )
end

private

# What a handler makes of its request while its connection is open, answered after it is closed.
enum Answer
  Redirect(String)
  SignedOut
end

def show(conn: Bond.Conn, pool: Database.Pool, pages: Optional[PageCache.Pages]) -> Result[Bond.Conn]
  query = Searches.words(first(try Bond.query_all(conn, "q")))
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Bond.redirect(conn, Routes.SIGN_IN))
    some(person) -> shown(conn, pool, pages, person, query, RoomsWeb.last_room_cookie(conn))
  end
end

# The version of the database is read before the page is made (`PageCache.search_spot`), so a page that is kept is
# never older than its key. A query that no form of ours sends (too long) is answered and not kept.
def shown(
  conn: Bond.Conn,
  pool: Database.Pool,
  pages: Optional[PageCache.Pages],
  person: Auth.User,
  query: String,
  wanted: Optional[Int],
) -> Result[Bond.Conn]
  spot: Optional[PageCache.Spot] = none
  if query.length <= Searches.MAX_QUERY_LENGTH
    spot = PageCache.search_spot(pages, PageCache.seen(conn), person, query, wanted)
  end

  kept = PageCache.lookup(spot)
  case kept
    some(page) -> ok(PageCache.respond(conn, page))
    none -> made(conn, pool, spot, person, query, wanted)
  end
end

def made(
  conn: Bond.Conn,
  pool: Database.Pool,
  spot: Optional[PageCache.Spot],
  person: Auth.User,
  query: String,
  wanted: Optional[Int],
) -> Result[Bond.Conn]
  html = try Database.with_connection(pool) do |db| results_page(db, person, query, wanted) end
  ok(PageCache.respond(conn, PageCache.keep(spot, html)))
end

def results_page(db: Db.Connection, person: Auth.User, query: String, wanted: Optional[Int]) -> Result[String]
  messages = try Searches.messages(db, person.id, query)
  recent = try Searches.recent(db, person.id)
  back = try back_path(db, person, wanted)
  ok(Views.search(try RoomsWeb.sidebar_of(db, person), query, messages, recent, back, person.id, person.role))
end

# The room that the link of the page goes back to (`@return_to_room` of Rails, which is `last_room_visited`), "" for a
# person in no room: Rails has nothing to link to then, and neither does the page.
def back_path(db: Db.Connection, person: Auth.User, wanted: Optional[Int]) -> Result[String]
  room = try Rooms.last_visited(db, person.id, wanted)
  case room
    some(found) -> ok(Routes.room_path(found.id))
    none -> ok("")
  end
end

def remember(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  query = Searches.words(first(try Bond.form_all(conn, "q")))
  answer = try Database.with_connection(pool) do |db| remembered(conn, db, query) end
  ok(respond(conn, answer))
end

# A query with no word, or one too long to keep, is not remembered; the person still goes to the results.
def remembered(conn: Bond.Conn, db: Db.Connection, query: String) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) -> ok(Answer.Redirect(try keep(db, person, query)))
  end
end

def keep(db: Db.Connection, person: Auth.User, query: String) -> Result[String]
  return ok(Routes.SEARCHES) if query.empty?

  if query.length <= Searches.MAX_QUERY_LENGTH
    try Searches.record(db, person.id, query)
  end

  ok(Routes.search_path(query))
end

# The button of Rails' page: a `POST` with `_method` set to `delete`; any other is a 405 that lists the methods of the
# path.
def post_clear(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  if method != Routes.METHOD_DELETE
    return ok(Bond.header(Bond.text(conn, 405, "method not allowed"), "allow", Routes.SEARCHES_CLEAR_ALLOW))
  end

  clear(conn, pool)
end

# Forgets the recent searches of the person who is signed in and of nobody else: the route names no one's searches, so
# there is no other person's to find or to refuse. Back to the page, as Rails does.
def clear(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| cleared(conn, db) end
  ok(respond(conn, answer))
end

def cleared(conn: Bond.Conn, db: Db.Connection) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) ->
      try Searches.clear(db, person.id)
      ok(Answer.Redirect(Routes.SEARCHES))
  end
end

# A page without `q` is a search for nothing, as Rails has it.
def first(values: List[String]) -> String
  return "" if values.empty?

  values[0]
end

def respond(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Redirect(path) -> Bond.redirect(conn, path)
    Answer.SignedOut -> Bond.redirect(conn, Routes.SIGN_IN)
  end
end

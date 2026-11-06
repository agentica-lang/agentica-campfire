## The search of messages: `GET /searches?q=words` shows the messages of the person's rooms that match, `POST
## /searches` remembers what they searched for (the form of the page posts it) and goes to the results. What a person
## types is words (`Searches.words`), never a search expression, so no query can make the index fail. The results are
## read on the same connection as the sidebar, and a page has no message of a room that the person is not in.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import Database from "../campfire/repo/database"
import RoomsWeb from "rooms"
import Routes from "routes"
import Searches from "../campfire/searches"
import Views from "views"

# What a handler makes of its request while its connection is open, answered after it is closed.
enum Answer
  Page(String)
  Redirect(String)
  SignedOut
end

## Adds the routes of the search to `app`. They are not in `AuthWeb.PUBLIC_PATHS`, so they need a sign-in.
export def add(app: Bond.App, pool: Database.Pool) -> Bond.App
  return (
    app
    |> Bond.get(Routes.SEARCHES) do |conn| show(conn, pool) end
    |> Bond.post(Routes.SEARCHES) do |conn| remember(conn, pool) end
  )
end

def show(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  query = Searches.words(first(try Bond.query_all(conn, "q")))
  answer = try Database.with_connection(pool) do |db| results_for(conn, db, query) end
  return ok(respond(conn, answer))
end

def results_for(conn: Bond.Conn, db: Db.Connection, query: String) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return ok(Answer.Page(try results_page(db, person, query)))
  end
end

def results_page(db: Db.Connection, person: Auth.User, query: String) -> Result[String]
  messages = try Searches.messages(db, person.id, query)
  recent = try Searches.recent(db, person.id)
  return ok(Views.search(try RoomsWeb.sidebar_of(db, person), query, messages, recent, person.id, person.role))
end

def remember(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  query = Searches.words(first(try Bond.form_all(conn, "q")))
  answer = try Database.with_connection(pool) do |db| remembered(conn, db, query) end
  return ok(respond(conn, answer))
end

# A query with no word, or one too long to keep, is not remembered; the person still goes to the results.
def remembered(conn: Bond.Conn, db: Db.Connection, query: String) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(Answer.SignedOut)
    some(person) -> return ok(Answer.Redirect(try keep(db, person, query)))
  end
end

def keep(db: Db.Connection, person: Auth.User, query: String) -> Result[String]
  if query.empty?
    return ok(Routes.SEARCHES)
  end

  if query.length <= Searches.MAX_QUERY_LENGTH
    try Searches.record(db, person.id, query)
  end

  return ok(Routes.search_path(query))
end

# A page without `q` is a search for nothing, as Rails has it.
def first(values: List[String]) -> String
  if values.empty?
    return ""
  end

  return values[0]
end

def respond(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Page(html) -> return Bond.html(conn, 200, html)
    Answer.Redirect(path) -> return Bond.redirect(conn, path)
    Answer.SignedOut -> return Bond.redirect(conn, Routes.SIGN_IN)
  end
end

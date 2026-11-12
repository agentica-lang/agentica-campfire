## The web side of boosts (`Messages::BoostsController` of Rails): the boosts of a message, the page that adds one, the
## post that adds it and the removal of one's own. The person is the one that the sign-in filter of `AuthWeb` looked up
## (`AuthWeb.assigned_user`), and they reach a message through the membership of its room (`Boosts.reach`): a message
## of a room they are not in and a message that does not exist are answered 404 with the same body, before the form is
## looked at, so no answer tells that a message exists. Only the booster takes a boost away: a boost of somebody else
## (an administrator is no exception), one of another message and one that is gone are the same 404, as `find_by!` is
## in Rails.
##
## A browser with the script of the page asks for a Turbo Stream and gets the boost to add, or the one to remove; a
## plain form is redirected to the room page around the message, where the boost shows. The people looking at the room
## hear of the change over `/cable`, after the connection is back in the pool.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import Blocks from "blocks"
import Boosts from "../campfire/boosts"
import CableWeb from "cable"
import Database from "../campfire/repo/database"
import Routes from "routes"
import Views from "views"

# The field of the form, as Rails nests it (`params.require(:boost)`), and the parts of the paths that name the message
# and the boost.
CONTENT = "boost[content]"
MESSAGE = "message_id"
BOOST = "id"

# What a request that asks for a Turbo Stream sends in `Accept`, and what the answer is typed.
TURBO_STREAM_TYPE = "text/vnd.turbo-stream.html"

# What a handler makes of its request, decided while its connection is open and answered after it is closed.
enum Answer
  Page(Int, String)
  Fragment(String)
  Added(Boosts.Reach, Boosts.Boost, Bool)
  Removed(Boosts.Reach, Int, Bool)
  NotFound
  NotAllowed(String)
  SignedOut
end

## Adds the routes of the boosts to `app`. They are not in `AuthWeb.PUBLIC_PATHS`, so they need a sign-in. `cable` is
## where a boost that is added or taken away is broadcast.
export def add(app: Bond.App, pool: Database.Pool, cable: CableWeb.Cable) -> Bond.App
  on_get_message_boosts = Blocks.handler() do |conn|
    served(conn, pool, cable) do |db, person| list_answer(conn, db, person) end
  end

  on_post_message_boosts = Blocks.handler() do |conn|
    served(conn, pool, cable) do |db, person| add_answer(conn, db, person, wants_stream?(conn)) end
  end

  on_get_message_boost_new = Blocks.handler() do |conn|
    served(conn, pool, cable) do |db, person| new_answer(conn, db, person) end
  end

  on_post_message_boost = Blocks.handler() do |conn| post_boost(conn, pool, cable) end

  (
    app
    |> Bond.get(Routes.MESSAGE_BOOSTS, on_get_message_boosts)
    |> Bond.post(Routes.MESSAGE_BOOSTS, on_post_message_boosts)
    |> Bond.get(Routes.MESSAGE_BOOST_NEW, on_get_message_boost_new)
    |> Bond.post(Routes.MESSAGE_BOOST, on_post_message_boost)
    |> Bond.delete(Routes.MESSAGE_BOOST) do |conn|
      served(conn, pool, cable) do |db, person| remove_answer(conn, db, person, wants_stream?(conn)) end
    end
  )
end

# The form of Rails posts to a boost with `_method` `delete` to take it away (in any case, as Rails reads it); any
# other post is a 405 that says which methods the path takes, whatever the boost.
def post_boost(conn: Bond.Conn, pool: Database.Pool, cable: CableWeb.Cable) -> Result[Bond.Conn]
  if try AuthWeb.form_method(conn) != Routes.METHOD_DELETE
    return ok(respond(conn, Answer.NotAllowed(Routes.MESSAGE_BOOST_ALLOW)))
  end

  served(conn, pool, cable) do |db, person| remove_answer(conn, db, person, wants_stream?(conn)) end
end

# One connection of the pool for the work of `handle`, then the broadcast and the answer.
def served(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  handle: Fn[Db.Connection, Auth.User, Result[Answer]],
) -> Result[Bond.Conn]
  answer = try Database.with_connection(pool) do |db| signed_in(conn, db, handle) end
  ok(announced(conn, cable, answer))
end

def signed_in(
  conn: Bond.Conn,
  db: Db.Connection,
  handle: Fn[Db.Connection, Auth.User, Result[Answer]],
) -> Result[Answer]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Answer.SignedOut)
    some(person) -> handle.call(db, person)
  end
end

# A browser that runs the script of the page asks for a Turbo Stream; a form that was sent without it gets
# the redirect.
def wants_stream?(conn: Bond.Conn) -> Bool
  accept = Bond.request_header(conn, "accept")
  accept.ok? and accept.unwrap!.include?(TURBO_STREAM_TYPE)
end

# The message that the path names, when the person is in its room.
def reached(conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Optional[Boosts.Reach]]
  id = Bond.param_int(conn, MESSAGE)
  return ok(none) if not id.ok?

  Boosts.reach(db, person.id, id.unwrap!)
end

def list_answer(conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Answer]
  found = try reached(conn, db, person)
  case found
    none -> ok(Answer.NotFound)
    some(reach) ->
      boosts = try Boosts.of_message(db, reach.message_id)
      ok(Answer.Fragment(Views.boosts_area(reach.message_id, boosts)))
  end
end

def new_answer(conn: Bond.Conn, db: Db.Connection, person: Auth.User) -> Result[Answer]
  found = try reached(conn, db, person)
  case found
    none -> ok(Answer.NotFound)
    some(reach) -> ok(Answer.Page(200, Views.new_boost(reach.room_id, reach.message_id, "", "")))
  end
end

# The text is read only after the right is checked, as everywhere, so that a 400 for a missing field does not tell a
# person who is not in the room that the message exists.
def add_answer(conn: Bond.Conn, db: Db.Connection, person: Auth.User, stream: Bool) -> Result[Answer]
  found = try reached(conn, db, person)
  case found
    none -> ok(Answer.NotFound)
    some(reach) -> added(conn, db, person, reach, stream)
  end
end

def added(conn: Bond.Conn, db: Db.Connection, person: Auth.User, reach: Boosts.Reach, stream: Bool) -> Result[Answer]
  content = (try Bond.form(conn, CONTENT)).strip
  problem = Boosts.content_problem(content)
  return ok(Answer.Page(422, Views.new_boost(reach.room_id, reach.message_id, content, problem))) if problem != ""

  # The insert stores nothing for a person who was deactivated or taken out of the room since the check, which is a
  # 404 as it would have been a moment earlier.
  stored = try Boosts.add(db, person.id, reach.message_id, content)
  case stored
    none -> ok(Answer.NotFound)
    some(boost) -> ok(Answer.Added(reach, boost, stream))
  end
end

def remove_answer(conn: Bond.Conn, db: Db.Connection, person: Auth.User, stream: Bool) -> Result[Answer]
  found = try reached(conn, db, person)
  case found
    none -> ok(Answer.NotFound)
    some(reach) -> removed(conn, db, person, reach, stream)
  end
end

def removed(conn: Bond.Conn, db: Db.Connection, person: Auth.User, reach: Boosts.Reach, stream: Bool) -> Result[Answer]
  id = Bond.param_int(conn, BOOST)
  return ok(Answer.NotFound) if not id.ok?

  gone = try Boosts.remove(db, person.id, reach.message_id, id.unwrap!)
  return ok(Answer.NotFound) if not gone

  ok(Answer.Removed(reach, id.unwrap!, stream))
end

# What the live clients hear of an answer, after its connection is back in the pool (a broadcast may wait for room in
# the hub), and then the answer itself.
def announced(conn: Bond.Conn, cable: CableWeb.Cable, answer: Answer) -> Bond.Conn
  case answer
    Answer.Added(reach, boost, _) -> CableWeb.boost_added(cable, reach.room_id, reach.message_id, boost)
    Answer.Removed(reach, boost_id, _) -> CableWeb.boost_removed(cable, reach.room_id, boost_id)
    _ -> return respond(conn, answer)
  end

  respond(conn, answer)
end

def respond(conn: Bond.Conn, answer: Answer) -> Bond.Conn
  case answer
    Answer.Page(status, html) -> Bond.html(conn, status, html)
    Answer.Fragment(html) -> Bond.html(conn, 200, html)
    Answer.Added(reach, boost, stream) if stream -> streamed(conn, Views.boost_added_stream(reach.message_id, boost))
    Answer.Added(reach, _, _) -> Bond.redirect(conn, back_to(reach))
    Answer.Removed(_, boost_id, stream) if stream -> streamed(conn, Views.boost_removed_stream(boost_id))
    Answer.Removed(reach, _, _) -> Bond.redirect(conn, back_to(reach))
    Answer.NotFound -> Bond.text(conn, 404, Routes.MISSING)
    Answer.NotAllowed(allow) -> Bond.header(Bond.text(conn, 405, "method not allowed"), "allow", allow)
    Answer.SignedOut -> Bond.redirect(conn, Routes.SIGN_IN)
  end
end

def streamed(conn: Bond.Conn, html: String) -> Bond.Conn
  Bond.header(Bond.html(conn, 200, html), "content-type", TURBO_STREAM_TYPE + "; charset=utf-8")
end

# The room page around the message, where its boosts are, whatever page of the room it is on.
def back_to(reach: Boosts.Reach) -> String
  "#{Routes.room_at_path(reach.room_id, reach.message_id)}#message_#{reach.message_id}"
end

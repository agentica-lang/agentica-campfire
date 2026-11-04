## The sidebar as a page of its own, `GET /users/me/sidebar`: what Rails loads in a frame of every page, here a whole
## document, so the rooms of the person (`shared_rooms`, then the direct messages) can be fetched alone. It is the same
## column that the other pages carry, so it lists the rooms that the person has not hidden (`Rooms.visible`).

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import AuthWeb from "auth"
import Database from "../campfire/repo/database"
import RoomsWeb from "rooms"
import Routes from "routes"
import Views from "views"

## Adds the route of the sidebar to `app`. It is not in `AuthWeb.PUBLIC_PATHS`, so it needs a sign-in.
export def add(app: Bond.App, pool: Database.Pool) -> Bond.App
  return app |> Bond.get(Routes.SIDEBAR) do |conn| show(conn, pool) end
end

def show(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  page = try Database.with_connection(pool) do |db| page_of(conn, db) end
  case page
    none -> return ok(Bond.redirect(conn, Routes.SIGN_IN))
    some(html) -> return ok(Bond.html(conn, 200, html))
  end
end

# `none` for a request that has no person, which the sign-in filter does not let through.
def page_of(conn: Bond.Conn, db: Db.Connection) -> Result[Optional[String]]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> return ok(none)
    some(person) -> return ok(some(Views.sidebar_page(try RoomsWeb.sidebar_of(db, person))))
  end
end

## The sidebar as a page of its own, `GET /users/me/sidebar`: what Rails loads in a frame of every page, here a whole
## document, so the rooms of the person (`shared_rooms`, then the direct messages) can be fetched alone. It is the same
## column that the other pages carry, so it lists the rooms that the person has not hidden (`Rooms.visible`).

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import CableWeb from "cable"
import Database from "../campfire/repo/database"
import PageCache from "page_cache"
import RoomsWeb from "rooms"
import Routes from "routes"
import Views from "views"

## Adds the route of the sidebar to `app`. It is not in `AuthWeb.PUBLIC_PATHS`, so it needs a sign-in. The page is kept
## whole in `pages` for one person and one version of the database (`PageCache`), as the room page is.
export def add(app: Bond.App, pool: Database.Pool, cable: CableWeb.Cable, pages: Optional[PageCache.Pages]) -> Bond.App
  app |> Bond.get(Routes.SIDEBAR) do |conn| show(conn, pool, cable, pages) end
end

# `none` for a request that has no person, which the sign-in filter does not let through.
def show(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  pages: Optional[PageCache.Pages],
) -> Result[Bond.Conn]
  user = try AuthWeb.assigned_user(conn)
  case user
    none -> ok(Bond.redirect(conn, Routes.SIGN_IN))
    some(person) -> shown(conn, pool, cable, pages, person)
  end
end

# The version of the database is read before the page is made (`PageCache.sidebar_spot`), so a page that is kept is
# never older than its key.
def shown(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  pages: Optional[PageCache.Pages],
  person: Auth.User,
) -> Result[Bond.Conn]
  spot = PageCache.sidebar_spot(pages, PageCache.seen(conn), person)
  kept = PageCache.lookup(spot)
  case kept
    some(page) -> ok(PageCache.respond(conn, page))
    none -> made(conn, pool, cable, spot, person)
  end
end

def made(
  conn: Bond.Conn,
  pool: Database.Pool,
  cable: CableWeb.Cable,
  spot: Optional[PageCache.Spot],
  person: Auth.User,
) -> Result[Bond.Conn]
  html = try Database.with_connection(pool) do |db| page_of(db, cable, person) end
  ok(PageCache.respond(conn, PageCache.keep(spot, html)))
end

def page_of(db: Db.Connection, cable: CableWeb.Cable, person: Auth.User) -> Result[String]
  sources = CableWeb.sidebar_sources(cable, person.id)
  ok(Views.sidebar_page(try RoomsWeb.sidebar_of(db, person), sources))
end

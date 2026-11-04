## The routes of the app, on Bond.

import Bond from "pkg/bond/bond"
import AccountsWeb from "accounts"
import AuthWeb from "auth"
import Database from "../campfire/repo/database"
import Mailer from "../campfire/mail/mailer"
import Routes from "routes"
import RoomsWeb from "rooms"
import {Config} from "../campfire/config"

BUSY = "The server is busy, try again in a moment"
RETRY_AFTER_SECONDS = "1"

struct Health
  status: String
  schema_version: Int
end

## The app with its routes: the home page, which needs a sign-in, the health check, which says the schema version that
## the database was migrated to, the routes of `AuthWeb`, which send email through `mailer`, and those of `RoomsWeb` and
## `AccountsWeb`.
export def build(config: Config, pool: Database.Pool, schema_version: Int, mailer: Mailer.Mailer) -> Bond.App
  return (
    Bond.app()
    |> AuthWeb.add(config, pool, mailer)
    |> RoomsWeb.add(pool)
    |> AccountsWeb.add(config, pool)
    |> Bond.get(Routes.HOME) do |conn| RoomsWeb.home(conn, pool) end
    |> Bond.get(Routes.HEALTH) do |conn| health(conn, schema_version) end
    |> Bond.not_found() do |conn| ok(Bond.text(conn, 404, Routes.MISSING)) end
    |> Bond.on_error() do |conn, message| failed(conn, message) end
  )
end

# A failure of the app is a 500 with no detail. One that ran out of time (no free connection within `checkout_ms`, a
# statement over its `timeout_ms`) is a busy server, not a broken one: 503 and a `Retry-After`, as the sign-in slots
# answer. Bond has written the message to stderr already.
def failed(conn: Bond.Conn, message: String) -> Result[Bond.Conn]
  if Database.timeout?(message)
    return ok(Bond.header(Bond.text(conn, 503, BUSY), "retry-after", RETRY_AFTER_SECONDS))
  end

  return ok(Bond.text(conn, 500, "Internal Server Error"))
end

# For a load balancer or a container check: 200 while the process serves, and the schema that it started on.
def health(conn: Bond.Conn, schema_version: Int) -> Result[Bond.Conn]
  return ok(Bond.json(conn, 200, JSON.from(Health(status: "ok", schema_version: schema_version))))
end

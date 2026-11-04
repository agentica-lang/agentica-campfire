## The routes of the app, on Bond.

import Bond from "pkg/bond/bond"
import AccountsWeb from "accounts_web"
import AuthWeb from "auth_web"
import Mailer from "mailer"
import Routes from "routes"
import RoomsWeb from "rooms_web"
import {Config} from "config"

# What a page that is not there answers. A room, a person or a join code that a visitor may not know of answers the
# same words (their handlers say them too), so no 404 tells which of them it is.
MISSING = "Not Found"

struct Health
  status: String
  schema_version: Int
end

## The app with its routes: the home page, which needs a sign-in, the health check, which says the schema version that
## the database was migrated to, the routes of `AuthWeb`, which send email through `mailer`, and those of `RoomsWeb` and `AccountsWeb`.
export def build(config: Config, schema_version: Int, mailer: Mailer.Mailer) -> Bond.App
  return (
    Bond.app()
    |> AuthWeb.add(config, mailer)
    |> RoomsWeb.add(config)
    |> AccountsWeb.add(config)
    |> Bond.get(Routes.HOME) do |conn| RoomsWeb.home(conn, config) end
    |> Bond.get(Routes.HEALTH) do |conn| health(conn, schema_version) end
    |> Bond.not_found() do |conn| ok(Bond.text(conn, 404, MISSING)) end
  )
end

# For a load balancer or a container check: 200 while the process serves, and the schema that it started on.
def health(conn: Bond.Conn, schema_version: Int) -> Result[Bond.Conn]
  return ok(Bond.json(conn, 200, JSON.from(Health(status: "ok", schema_version: schema_version))))
end

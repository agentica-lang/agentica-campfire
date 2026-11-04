## The routes of the app, on Bond.

import Bond from "pkg/bond/bond"
import AccountsWeb from "accounts"
import AuthWeb from "auth"
import Mailer from "../campfire/mail/mailer"
import Routes from "routes"
import RoomsWeb from "rooms"
import {Config} from "../campfire/config"

struct Health
  status: String
  schema_version: Int
end

## The app with its routes: the home page, which needs a sign-in, the health check, which says the schema version that
## the database was migrated to, the routes of `AuthWeb`, which send email through `mailer`, and those of `RoomsWeb` and
## `AccountsWeb`.
export def build(config: Config, schema_version: Int, mailer: Mailer.Mailer) -> Bond.App
  return (
    Bond.app()
    |> AuthWeb.add(config, mailer)
    |> RoomsWeb.add(config)
    |> AccountsWeb.add(config)
    |> Bond.get(Routes.HOME) do |conn| RoomsWeb.home(conn, config) end
    |> Bond.get(Routes.HEALTH) do |conn| health(conn, schema_version) end
    |> Bond.not_found() do |conn| ok(Bond.text(conn, 404, Routes.MISSING)) end
  )
end

# For a load balancer or a container check: 200 while the process serves, and the schema that it started on.
def health(conn: Bond.Conn, schema_version: Int) -> Result[Bond.Conn]
  return ok(Bond.json(conn, 200, JSON.from(Health(status: "ok", schema_version: schema_version))))
end

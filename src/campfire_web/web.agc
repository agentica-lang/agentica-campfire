## The routes of the app, on Bond.

import Bond from "pkg/bond/bond"
import AccountsWeb from "accounts"
import AuthWeb from "auth"
import Database from "../campfire/repo/database"
import Failure from "failure"
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
export def build(config: Config, pool: Database.Pool, schema_version: Int, mailer: Mailer.Mailer) -> Bond.App
  return (
    Bond.app()
    |> AuthWeb.add(config, pool, mailer)
    |> RoomsWeb.add(pool)
    |> AccountsWeb.add(config, pool)
    |> Bond.get(Routes.HOME) do |conn| RoomsWeb.home(conn, pool) end
    |> Bond.get(Routes.HEALTH) do |conn| health(conn, schema_version) end
    |> Bond.not_found() do |conn| ok(Bond.text(conn, 404, Routes.MISSING)) end
    |> Bond.on_error() do |conn, message| ok(Failure.answer(conn, message)) end
  )
end

# For a load balancer or a container check: 200 while the process serves, and the schema that it started on.
def health(conn: Bond.Conn, schema_version: Int) -> Result[Bond.Conn]
  return ok(Bond.json(conn, 200, JSON.from(Health(status: "ok", schema_version: schema_version))))
end

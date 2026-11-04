## The routes of the app, on Bond.

import Bond from "pkg/bond/bond"
import AccountsWeb from "accounts"
import AuthWeb from "auth"
import AvatarsWeb from "avatars"
import Database from "../campfire/repo/database"
import Failure from "failure"
import Mailer from "../campfire/mail/mailer"
import Routes from "routes"
import RoomsWeb from "rooms"
import SearchesWeb from "searches"
import SidebarsWeb from "sidebars"
import SignedId from "../campfire/signed_id"
import {Config} from "../campfire/config"

UP_PAGE = "<!DOCTYPE html><html><body style=\"background-color: green\"></body></html>"

# The biggest file that the assets folder serves: 4 MiB, far above a stylesheet or a script of this app.
STYLESHEET_MAX_BYTES = 4 * 1024 * 1024

struct Health
  status: String
  schema_version: Int
end

## The app with its routes: the home page, which needs a sign-in, the health check, which says the schema version that
## the database was migrated to, the routes of `AuthWeb`, which send email through `mailer`, those of `RoomsWeb` and
## `AccountsWeb`, the sidebar, the search, the avatars (checked with the key of `SECRET_KEY_BASE`) and the folder of the
## stylesheet. `config.assets_dir` must be a folder, which `App.start` checks.
export def build(config: Config, pool: Database.Pool, schema_version: Int, mailer: Mailer.Mailer) -> Bond.App
  return (
    Bond.app()
    |> AuthWeb.add(config, pool, mailer)
    |> RoomsWeb.add(pool)
    |> AccountsWeb.add(config, pool)
    |> SidebarsWeb.add(pool)
    |> SearchesWeb.add(pool)
    |> AvatarsWeb.add(pool, avatar_key(config), config.storage_dir)
    |> Bond.static(Routes.ASSETS, config.assets_dir, STYLESHEET_MAX_BYTES, 0, true)
    |> Bond.get(Routes.HOME) do |conn| RoomsWeb.home(conn, pool) end
    |> Bond.get(Routes.HEALTH) do |conn| health(conn, schema_version) end
    |> Bond.get(Routes.UP) do |conn| up(conn) end
    |> Bond.not_found() do |conn| ok(Bond.text(conn, 404, Routes.MISSING)) end
    |> Bond.on_error() do |conn, message| ok(Failure.answer(conn, message)) end
  )
end

# For a load balancer or a container check: 200 while the process serves, and the schema that it started on.
def health(conn: Bond.Conn, schema_version: Int) -> Result[Bond.Conn]
  return ok(Bond.json(conn, 200, JSON.from(Health(status: "ok", schema_version: schema_version))))
end

# What `/up` of Rails answers, so a check made for Rails (the benchmark harness looks for the colour) works here.
def up(conn: Bond.Conn) -> Result[Bond.Conn]
  return ok(Bond.html(conn, 200, UP_PAGE))
end

# The key that the avatar links are checked with, from `SECRET_KEY_BASE`; `none` without one, so no link is valid. A
# secret that is set always makes a key (PBKDF2 with fixed sizes cannot fail), so `none` only means "not set".
def avatar_key(config: Config) -> Optional[Bytes]
  if config.secret_key_base.empty?
    return none
  end

  key = SignedId.key(config.secret_key_base)
  if not key.ok?
    return none
  end

  return some(key.unwrap!)
end

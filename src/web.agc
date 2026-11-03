## The routes of the app, on Bond.

import Bond from "pkg/bond/bond"
import AuthWeb from "auth_web"
import Views from "views"
import {Config} from "config"

struct Health
  status: String
  schema_version: Int
end

## The app with its routes: the home page, which needs a sign-in, the health check, which says the schema version that
## the database was migrated to, and the routes of `AuthWeb`.
export def build(config: Config, schema_version: Int) -> Bond.App
  return (
    Bond.app()
    |> AuthWeb.add(config)
    |> Bond.get("/") do |conn| home(conn, config) end
    |> Bond.get("/health") do |conn| health(conn, schema_version) end
  )
end

# The filter of `AuthWeb` lets only a signed-in person get here, but a session that ended after it (a race with
# a sign-out) is the sign-in page again.
def home(conn: Bond.Conn, config: Config) -> Result[Bond.Conn]
  user = try AuthWeb.current_user(conn, config)
  case user
    some(person) -> return ok(Bond.html(conn, 200, Views.home(person.name)))
    none -> return ok(Bond.redirect(conn, "/session/new"))
  end
end

# For a load balancer or a container check: 200 while the process serves, and the schema that it started on.
def health(conn: Bond.Conn, schema_version: Int) -> Result[Bond.Conn]
  return ok(Bond.json(conn, 200, JSON.from(Health(status: "ok", schema_version: schema_version))))
end

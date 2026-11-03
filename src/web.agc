## The routes of the app, on Bond.

import Bond from "pkg/bond/bond"
import Views from "views"

struct Health
  status: String
  schema_version: Int
end

## The app with its routes: the home page and the health check, which says the schema version that the database was
## migrated to.
export def build(schema_version: Int) -> Bond.App
  return Bond.app() |> Bond.get("/", &home) |> Bond.get("/health") do |conn| health(conn, schema_version) end
end

def home(conn: Bond.Conn) -> Result[Bond.Conn]
  return ok(Bond.html(conn, 200, Views.home()))
end

# For a load balancer or a container check: 200 while the process serves, and the schema that it started on.
def health(conn: Bond.Conn, schema_version: Int) -> Result[Bond.Conn]
  return ok(Bond.json(conn, 200, JSON.from(Health(status: "ok", schema_version: schema_version))))
end

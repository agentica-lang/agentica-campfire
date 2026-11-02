## The app: the routes of Bond, and the server that runs them.

import Bond from "pkg/bond/bond"
import Views from "views"
import {Config} from "config"

## The app with its routes: the home page and the health check.
export def build() -> Bond.App
  return Bond.app() |> Bond.get("/", &home) |> Bond.get("/health", &health)
end

## Serves the app on the address of `config`, says where on its first line of output (`listening on http://HOST:PORT`,
## with the real port when the config asks for 0), and waits until the server stops. A failure to listen is an
## `error`.
export def run(config: Config) -> Result[Void]
  server = try Bond.start(build(), config.host, config.port)
  puts("listening on http://#{config.host}:#{Bond.local_port(server)}")
  IO.flush()
  return Bond.wait(server)
end

def home(conn: Bond.Conn) -> Result[Bond.Conn]
  return ok(Bond.html(conn, 200, Views.home()))
end

# For a load balancer or a container check: 200 while the process serves.
def health(conn: Bond.Conn) -> Result[Bond.Conn]
  return ok(Bond.json(conn, 200, JSON.from({"status": "ok"})))
end

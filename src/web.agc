## The app: the routes of Bond, and the server that runs them.

import Bond from "pkg/bond/bond"
import Views from "views"
import {Config} from "config"

## The app with its routes: the home page and the health check.
export def build() -> Bond.App
  return Bond.app() |> Bond.get("/", &home) |> Bond.get("/health", &health)
end

## Serves the app on the address of `config`, says where on its first line of output (`listening on http://HOST:PORT`,
## with the real port when the config asks for 0, and `[HOST]` for an IPv6 host), and waits until the server stops. A
## failure to listen is an `error` that names `CAMPFIRE_HOST` and `CAMPFIRE_PORT`.
export def run(config: Config) -> Result[Void]
  started = Bond.start(build(), config.host, config.port)
  if not started.ok?
    # The system's message names the host and the port, not the variables that a person has to change.
    return error("cannot listen on #{config.host}:#{config.port} (CAMPFIRE_HOST, CAMPFIRE_PORT): #{started.message}")
  end

  server = started.unwrap!
  puts("listening on #{origin(config.host, Bond.local_port(server))}")
  IO.flush()
  return Bond.wait(server)
end

# `http://HOST:PORT`, with the brackets that a URL needs round an IPv6 host.
def origin(host: String, port: Int) -> String
  if host.include?(":")
    return "http://[#{host}]:#{port}"
  end

  return "http://#{host}:#{port}"
end

def home(conn: Bond.Conn) -> Result[Bond.Conn]
  return ok(Bond.html(conn, 200, Views.home()))
end

# For a load balancer or a container check: 200 while the process serves.
def health(conn: Bond.Conn) -> Result[Bond.Conn]
  return ok(Bond.json(conn, 200, JSON.from({"status": "ok"})))
end

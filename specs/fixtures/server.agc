## The program of the features: the app on the address and the database of its environment (CAMPFIRE_HOST,
## CAMPFIRE_PORT and CAMPFIRE_DATABASE_URL, which the steps set), as `campfire.agc` reads them. It prints the lines
## that `App.start` does. A line `restart` on its input stops the server and starts another on the same database, and
## the end of input stops the program.

import App from "../../src/app"
import Bond from "pkg/bond/bond"
import Config from "../../src/config"

def main() -> Void
  case Config.load()
    error(message) -> fail(message)
    ok(config) -> serve(config, start(config))
  end
end

# `restart` goes back to the same database: the migrations run again and find nothing to do.
def serve(config: Config.Config, server: HttpServer) -> Void
  line = IO.gets()
  if not line.ok?
    return
  end

  if line.unwrap! == "restart"
    Bond.stop(server)
    serve(config, start(config))
  end
end

def start(config: Config.Config) -> HttpServer
  started = App.start(config)
  if not started.ok?
    fail(started.message)
  end

  return started.unwrap!
end

def fail(message: String) -> Void
  IO.warn("campfire: #{message}")
  System.exit(1)
end

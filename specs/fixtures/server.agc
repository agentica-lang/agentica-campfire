## The program of the features: the app on the address and the database of its environment (CAMPFIRE_HOST,
## CAMPFIRE_PORT and CAMPFIRE_DATABASE_URL, which the steps set), as `campfire.agc` reads them. It prints the lines
## that `App.start` does. A line `restart` on its input stops the server and starts another on the same database, and
## the end of input stops the program, once the mailer has sent what it had.

import App from "../../src/campfire_web/app"
import Config from "../../src/campfire/config"

private

def main() -> Void
  case Config.load()
    error(message) -> fail(message.message)
    ok(config) -> serve(config, start(config))
  end
end

# `restart` goes back to the same database: the migrations run again and find nothing to do.
def serve(config: Config.Config, running: App.Running) -> Void
  line = IO.gets()
  if not line.ok?
    App.stop(running)
    return
  end

  if line.unwrap! == "restart"
    App.stop(running)
    serve(config, start(config))
  elsif line.unwrap! == "restart without cache"
    App.stop(running)
    serve(config, start(config.with(cache_mb: 0)))
  elsif line.unwrap! == "restart without page cache"
    App.stop(running)
    serve(config, start(config.with(response_cache_mb: 0)))
  end
end

def start(config: Config.Config) -> App.Running
  started = App.start(config)
  if not started.ok?
    fail(started.message)
  end

  started.unwrap!
end

def fail(message: String) -> Void
  IO.warn("campfire: #{message}")
  System.exit(1)
end

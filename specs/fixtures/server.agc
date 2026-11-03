## The program of the features: the app on 127.0.0.1 and a free port. The first input line is the database url. It
## prints the lines that `App.start` does. A later line `restart` stops the server and starts another on the same
## database, and the end of input stops the program.

import App from "../../src/app"
import Bond from "pkg/bond/bond"
import Config from "../../src/config"

def main() -> Void
  url = IO.gets().unwrap_or("")
  config = Config.parse("127.0.0.1", "0", "unused", url).unwrap!
  serve(config, start(config))
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
    IO.warn("campfire: #{started.message}")
    System.exit(1)
  end

  return started.unwrap!
end

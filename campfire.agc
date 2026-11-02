## The program: `agentica campfire.agc` (or `make run`). It listens on CAMPFIRE_HOST and CAMPFIRE_PORT
## (127.0.0.1 and 3000 by default).

import Config from "src/config"
import Web from "src/web"

def main() -> Void
  case Config.load()
    error(message) -> fail(message)
    ok(config) ->
      served = Web.run(config)
      if not served.ok?
        fail(served.message)
      end
  end
end

def fail(message: String) -> Void
  IO.warn("campfire: #{message}")
  System.exit(1)
end

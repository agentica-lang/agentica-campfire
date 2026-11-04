## The program: `agentica campfire.agc` (or `make run`). It opens the database (CAMPFIRE_DATABASE_URL, a file in
## CAMPFIRE_DATA_DIR by default), runs its migrations, then listens on CAMPFIRE_HOST and CAMPFIRE_PORT (127.0.0.1 and
## 3000 by default). CAMPFIRE_SESSION_SECRET (32 bytes or more) signs the session cookie and has no default.

import Config from "src/campfire/config"
import App from "src/campfire_web/app"
import DataDir from "src/campfire/data_dir"

def main() -> Void
  case Config.load()
    error(message) -> fail(message)
    ok(config) ->
      made = DataDir.ensure(config.data_dir)
      if not made.ok?
        fail("cannot make the data folder #{config.data_dir} (CAMPFIRE_DATA_DIR): #{made.message}")
      end

      served = App.run(config)
      if not served.ok?
        fail(served.message)
      end
  end
end

def fail(message: String) -> Void
  IO.warn("campfire: #{message}")
  System.exit(1)
end

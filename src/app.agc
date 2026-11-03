## The app as a program runs it: the database first, then the server.

import Bond from "pkg/bond/bond"
import Database from "database"
import Web from "web"
import {Config} from "config"

## Opens the database and runs its migrations, then serves the app on the address of `config`. It says what it did on
## two lines of output: `database: schema version N, migrations applied: M`, then `listening on http://HOST:PORT`
## (with the real port when the config asks for 0, and `[HOST]` for an IPv6 host). An `error` is a database that
## cannot be opened or migrated (it names `CAMPFIRE_DATABASE_URL`), or a failure to listen (it names `CAMPFIRE_HOST`
## and `CAMPFIRE_PORT`). The server belongs to the task that calls this.
export def start(config: Config) -> Result[HttpServer]
  migrated = Database.migrate(config.database_url)
  if not migrated.ok?
    return error(
      "cannot open or migrate the database (CAMPFIRE_DATABASE_URL, or CAMPFIRE_DATA_DIR when the url is not set): " +
      "#{migrated.message}",
    )
  end

  schema = migrated.unwrap!
  puts("database: schema version #{schema.version}, migrations applied: #{schema.applied.length}")
  started = Bond.start(Web.build(schema.version), config.host, config.port)
  if not started.ok?
    # The system's message names the host and the port, not the variables that a person has to change.
    return error("cannot listen on #{config.host}:#{config.port} (CAMPFIRE_HOST, CAMPFIRE_PORT): #{started.message}")
  end

  server = started.unwrap!
  puts("listening on #{origin(config.host, Bond.local_port(server))}")
  IO.flush()
  return ok(server)
end

## Starts the app and waits until the server stops.
export def run(config: Config) -> Result[Void]
  server = try start(config)
  return Bond.wait(server)
end

# `http://HOST:PORT`, with the brackets that a URL needs round an IPv6 host.
def origin(host: String, port: Int) -> String
  if host.include?(":")
    return "http://[#{host}]:#{port}"
  end

  return "http://#{host}:#{port}"
end

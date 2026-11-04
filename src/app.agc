## The app as a program runs it: the database first, then the server.

import Bond from "pkg/bond/bond"
import Database from "database"
import Mailer from "mailer"
import Web from "web"
import {Config, plain_link?} from "config"

## The server and the mailer that a start made, for `stop` and `wait`.
export struct Running
  server: HttpServer
  mailer: Mailer.Mailer
end

## Opens the database and runs its migrations, starts the mailer, then serves the app on the address of `config`. It
## says what it did on four lines of output: whether the session cookie is `Secure`, whether email is off or where it
## goes (`mail: ...`), `database: schema version N, migrations applied: M`, then `listening on http://HOST:PORT`
## (with the real port when the config asks for 0, and `[HOST]` for an IPv6 host). An `error` is a database that
## cannot be opened or migrated (it names `CAMPFIRE_DATABASE_URL`), or a failure to listen (it names `CAMPFIRE_HOST`
## and `CAMPFIRE_PORT`). The server and the mailer belong to the task that calls this.
export def start(config: Config) -> Result[Running]
  puts(cookie_line(config.secure_cookies))
  puts(Mailer.status(config.smtp))
  if config.smtp.some? and plain_link?(config)
    IO.warn(
      "campfire: warning: CAMPFIRE_BASE_URL is http:// for a host that is not this machine, " +
      "so the links in emails and what follows them go over plain HTTP",
    )
  end

  migrated = Database.migrate(config.database_url)
  if not migrated.ok?
    return error(
      "cannot open or migrate the database (CAMPFIRE_DATABASE_URL, or CAMPFIRE_DATA_DIR when the url is not set): " +
      "#{migrated.message}",
    )
  end

  schema = migrated.unwrap!
  puts("database: schema version #{schema.version}, migrations applied: #{schema.applied.length}")
  mailer = Mailer.start(config.smtp, config.mail_queue)
  started = Bond.start(Web.build(config, schema.version, mailer), config.host, config.port)
  if not started.ok?
    Mailer.stop(mailer)
    # The system's message names the host and the port, not the variables that a person has to change.
    return error("cannot listen on #{config.host}:#{config.port} (CAMPFIRE_HOST, CAMPFIRE_PORT): #{started.message}")
  end

  server = started.unwrap!
  puts("listening on #{origin(config.host, Bond.local_port(server))}")
  IO.flush()
  return ok(Running(server: server, mailer: mailer))
end

## Stops the server, then the mailer, which sends what is queued first.
export def stop(running: Running) -> Void
  Bond.stop(running.server)
  Mailer.stop(running.mailer)
end

## Starts the app and waits until the server stops, then lets the mailer finish what is queued.
export def run(config: Config) -> Result[Void]
  running = try start(config)
  waited = Bond.wait(running.server)
  Mailer.stop(running.mailer)
  return waited
end

# A cookie without `Secure` travels over plain HTTP, so the line tells a person who forgot the setting behind HTTPS.
def cookie_line(secure_cookies: Bool) -> String
  if secure_cookies
    return "session cookie: Secure, with the __Host- prefix"
  end

  return "session cookie: not Secure (set CAMPFIRE_SECURE_COOKIES=true behind HTTPS)"
end

# `http://HOST:PORT`, with the brackets that a URL needs round an IPv6 host.
def origin(host: String, port: Int) -> String
  if host.include?(":")
    return "http://[#{host}]:#{port}"
  end

  return "http://#{host}:#{port}"
end

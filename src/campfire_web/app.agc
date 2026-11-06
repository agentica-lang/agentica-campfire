## The app as a program runs it: the database first, then the server.

import Bond from "pkg/bond/bond"
import CableWeb from "cable"
import Database from "../campfire/repo/database"
import Mailer from "../campfire/mail/mailer"
import MessageCache from "message_cache"
import PageCache from "page_cache"
import Web from "web"
import {Config, plain_link?} from "../campfire/config"

## The server, the mailer and the pool of database connections that a start made, for `stop` and `wait`.
export struct Running
  server: HttpServer
  mailer: Mailer.Mailer
  pool: Database.Pool
  pages: Optional[PageCache.Pages]
  cable: CableWeb.Cable
end

## Opens the database and runs its migrations, opens the pool of connections that the requests share, starts the
## mailer, then serves the app on the address of `config`. It says what it did on four lines of output: whether the
## session cookie is `Secure`, whether email is off or where it goes (`mail: ...`),
## `database: schema version N, migrations applied: M`, then `listening on http://HOST:PORT` (with the real port
## when the config asks for 0, and `[HOST]` for an IPv6 host). An `error` is a database that
## cannot be opened or migrated (it names `CAMPFIRE_DATABASE_URL`), an assets folder that is not there
## (`CAMPFIRE_ASSETS_DIR`), or a failure to listen (it names `CAMPFIRE_HOST`
## and `CAMPFIRE_PORT`). The server, the mailer and the pool belong to the task that calls this, which must live as long
## as the app does (the pool opens its connections in it).
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
  if schema.rails
    puts("database: made by Rails, opened as it is, schema version #{schema.version}")
  else
    puts("database: schema version #{schema.version}, migrations applied: #{schema.applied.length}")
  end

  opened = Database.open_pool(config.database_url, config.db_pool_size, config.db_checkout_ms)
  if not opened.ok?
    return error("cannot open the database connections (CAMPFIRE_DATABASE_URL): #{opened.message}")
  end

  pool = opened.unwrap!
  running = listen(config, pool, schema.version)
  if not running.ok?
    Database.close_pool(pool)
  end

  return running
end

## Stops the server, then the hub (its connections are told to reconnect), then the mailer, which sends what is queued
## first, then closes the pool.
export def stop(running: Running) -> Void
  Bond.stop(running.server)
  CableWeb.stop(running.cable)
  Mailer.stop(running.mailer)
  PageCache.stop(running.pages)
  Database.close_pool(running.pool)
end

## Starts the app and waits until the server stops, then lets the mailer finish what is queued and closes the pool.
export def run(config: Config) -> Result[Void]
  running = try start(config)
  waited = Bond.wait(running.server)
  CableWeb.stop(running.cable)
  Mailer.stop(running.mailer)
  PageCache.stop(running.pages)
  Database.close_pool(running.pool)
  return waited
end

# The mailer, then the server on the pool. The caller closes the pool when this fails.
def listen(config: Config, pool: Database.Pool, schema_version: Int) -> Result[Running]
  # `Bond.static` stops the program for a folder that is not there, so the start says which variable to change.
  assets = File.stat(config.assets_dir)
  if not assets.ok? or assets.unwrap!.kind != "directory"
    return error("the folder of the stylesheet is not there (CAMPFIRE_ASSETS_DIR): #{config.assets_dir}")
  end

  mailer = try Mailer.start(config.smtp, config.mail_queue)
  cable = try CableWeb.start(config, pool)
  messages = MessageCache.start(config.cache_mb)
  watched = PageCache.start(config.response_cache_mb, config.database_url, config.db_checkout_ms)
  if not watched.ok?
    CableWeb.stop(cable)
    Mailer.stop(mailer)
    return error(
      "cannot open the database connection that watches for changes (CAMPFIRE_DATABASE_URL): #{watched.message}",
    )
  end

  pages = watched.unwrap!
  # A WebSocket holds a connection of the server for as long as its tab is open, so the limit is a setting.
  limits = HttpServerOptions(max_connections: config.max_connections)
  started = Bond.start_with(
    Web.build(config, pool, schema_version, mailer, cable, messages, pages),
    config.host,
    config.port,
    limits,
  )

  if not started.ok?
    CableWeb.stop(cable)
    Mailer.stop(mailer)
    PageCache.stop(pages)
    # The system's message names the host and the port, not the variables that a person has to change.
    return error("cannot listen on #{config.host}:#{config.port} (CAMPFIRE_HOST, CAMPFIRE_PORT): #{started.message}")
  end

  server = started.unwrap!
  puts("listening on #{origin(config.host, Bond.local_port(server))}")
  IO.flush()
  return ok(Running(server: server, mailer: mailer, pool: pool, pages: pages, cable: cable))
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

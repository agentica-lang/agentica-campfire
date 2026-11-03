## Where the server listens, where its data lives and the secret that signs the session cookie. It is read from the
## environment, so the same program runs on a laptop and in a container.

## The host and the port when the environment says nothing: only this machine, on a port that is free in most setups.
## The port is text, like the variable that it stands for, so `parse` can take it as a default.
export DEFAULT_HOST = "127.0.0.1"
export DEFAULT_PORT = "3000"

## The folder for the files of the app (the database now, the uploads later), relative to where the program runs.
export DEFAULT_DATA_DIR = "data"

## The shortest session secret, the size of the SHA-256 digest that signs the cookie (Bond refuses a shorter one).
export MIN_SECRET_BYTES = 32

## Cookies are `Secure` only when the environment says so, since a browser drops them on plain HTTP (a laptop).
export DEFAULT_SECURE_COOKIES = "false"

## The address to listen on, the data folder and the url of the database. Port 0 asks the system for a free port (the
## specs use it). `session_secret` signs the session cookie and has no default, since a default is a secret that
## everyone knows. `secure_cookies` is for an app behind HTTPS.
export struct Config
  host: String
  port: Int
  data_dir: String
  database_url: String
  session_secret: String
  secure_cookies: Bool
end

## The `Config` of `CAMPFIRE_HOST`, `CAMPFIRE_PORT`, `CAMPFIRE_DATA_DIR`, `CAMPFIRE_DATABASE_URL`,
## `CAMPFIRE_SESSION_SECRET` and `CAMPFIRE_SECURE_COOKIES`, with the defaults for a variable that is not set (the
## secret has none). An `error` says which value is wrong.
export def load() -> Result[Config]
  host = System.env("CAMPFIRE_HOST").unwrap_or(DEFAULT_HOST)
  port = System.env("CAMPFIRE_PORT").unwrap_or(DEFAULT_PORT)
  data_dir = System.env("CAMPFIRE_DATA_DIR").unwrap_or(DEFAULT_DATA_DIR)
  database_url = System.env("CAMPFIRE_DATABASE_URL").unwrap_or("")
  secret = System.env("CAMPFIRE_SESSION_SECRET").unwrap_or("")
  secure_cookies = System.env("CAMPFIRE_SECURE_COOKIES").unwrap_or(DEFAULT_SECURE_COOKIES)
  return parse(host, port, data_dir, database_url, secret, secure_cookies)
end

## A `Config` from the text of a host, a port, a data folder, a database url, a session secret and the secure cookies
## flag, each the default when left out: an `error` for an empty host or data folder, a data folder with a `?`, a port
## that is not a number from 0 to 65535, a secret of less than 32 bytes (the default, an empty one, is that) and a flag
## that is not `true` or `false`. An empty `database_url` means the file `campfire.db` in the data folder, with the
## FTS5 check on, so that a SQLite without FTS5 stops the start with a clear message.
export def parse(
  host: String = DEFAULT_HOST,
  port: String = DEFAULT_PORT,
  data_dir: String = DEFAULT_DATA_DIR,
  database_url: String = "",
  session_secret: String = "",
  secure_cookies: String = DEFAULT_SECURE_COOKIES,
) -> Result[Config]
  if host.strip.empty?
    return error("CAMPFIRE_HOST is empty")
  end

  if data_dir.strip.empty?
    return error("CAMPFIRE_DATA_DIR is empty")
  end

  if data_dir.include?("?")
    return error("CAMPFIRE_DATA_DIR must not contain ?, since it starts the parameters of the database url")
  end

  number = port.strip.to_i
  if not number.ok? or number.unwrap! < 0 or number.unwrap! > 65535
    return error("CAMPFIRE_PORT must be a number from 0 to 65535, not #{port.inspect}")
  end

  if session_secret.bytes.size < MIN_SECRET_BYTES
    return error(
      "CAMPFIRE_SESSION_SECRET must have at least #{MIN_SECRET_BYTES} bytes (make one with: openssl rand -hex 32)",
    )
  end

  if secure_cookies != "true" and secure_cookies != "false"
    return error("CAMPFIRE_SECURE_COOKIES must be true or false, not #{secure_cookies.inspect}")
  end

  folder = data_dir.strip
  url = database_url.strip
  if url.empty?
    url = "sqlite:#{folder}/campfire.db?fts5=required"
  end

  return ok(
    Config(
      host: host.strip,
      port: number.unwrap!,
      data_dir: folder,
      database_url: url,
      session_secret: session_secret,
      secure_cookies: secure_cookies == "true",
    ),
  )
end

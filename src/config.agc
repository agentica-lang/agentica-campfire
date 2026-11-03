## Where the server listens and where its data lives. It is read from the environment, so the same program runs on a
## laptop and in a container.

## The host and the port when the environment says nothing: only this machine, on a port that is free in most setups.
## The port is text, like the variable that it stands for, so `parse` can take it as a default.
export DEFAULT_HOST = "127.0.0.1"
export DEFAULT_PORT = "3000"

## The folder for the files of the app (the database now, the uploads later), relative to where the program runs.
export DEFAULT_DATA_DIR = "data"

## The address to listen on, the data folder and the url of the database. Port 0 asks the system for a free port (the
## specs use it).
export struct Config
  host: String
  port: Int
  data_dir: String
  database_url: String
end

## The `Config` of `CAMPFIRE_HOST`, `CAMPFIRE_PORT`, `CAMPFIRE_DATA_DIR` and `CAMPFIRE_DATABASE_URL`, with the
## defaults for a variable that is not set. An `error` says which value is wrong.
export def load() -> Result[Config]
  host = System.env("CAMPFIRE_HOST").unwrap_or(DEFAULT_HOST)
  port = System.env("CAMPFIRE_PORT").unwrap_or(DEFAULT_PORT)
  data_dir = System.env("CAMPFIRE_DATA_DIR").unwrap_or(DEFAULT_DATA_DIR)
  database_url = System.env("CAMPFIRE_DATABASE_URL").unwrap_or("")
  return parse(host, port, data_dir, database_url)
end

## A `Config` from the text of a host, a port, a data folder and a database url, each the default when left out: an
## `error` for an empty host or data
## folder, a data folder with a `?`, and for a port that is not a number from 0 to 65535. An empty `database_url` means
## the file `campfire.db` in the data folder, with the FTS5 check on, so that a SQLite without FTS5 stops the start
## with a clear message.
export def parse(
  host: String = DEFAULT_HOST,
  port: String = DEFAULT_PORT,
  data_dir: String = DEFAULT_DATA_DIR,
  database_url: String = "",
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

  folder = data_dir.strip
  url = database_url.strip
  if url.empty?
    url = "sqlite:#{folder}/campfire.db?fts5=required"
  end

  return ok(Config(host: host.strip, port: number.unwrap!, data_dir: folder, database_url: url))
end

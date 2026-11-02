## Where the server listens. It is read from the environment, so the same program runs on a laptop and in a container.

## The host and the port when the environment says nothing: only this machine, on a port that is free in most setups.
export DEFAULT_HOST = "127.0.0.1"
export DEFAULT_PORT = 3000

## The address to listen on. Port 0 asks the system for a free port (the specs use it).
export struct Config
  host: String
  port: Int
end

## The `Config` of `CAMPFIRE_HOST` and `CAMPFIRE_PORT`, with the defaults for a variable that is not set. An `error`
## says which value is wrong.
export def load() -> Result[Config]
  host = System.env("CAMPFIRE_HOST").unwrap_or(DEFAULT_HOST)
  port = System.env("CAMPFIRE_PORT").unwrap_or(DEFAULT_PORT.to_s)
  return parse(host, port)
end

## A `Config` from the text of a host and a port: an `error` for an empty host, and for a port that is not a number
## from 0 to 65535.
export def parse(host: String, port: String) -> Result[Config]
  if host.strip.empty?
    return error("CAMPFIRE_HOST is empty")
  end

  number = port.strip.to_i
  if not number.ok? or number.unwrap! < 0 or number.unwrap! > 65535
    return error("CAMPFIRE_PORT must be a number from 0 to 65535, not #{port.inspect}")
  end

  return ok(Config(host: host.strip, port: number.unwrap!))
end

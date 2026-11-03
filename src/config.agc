## Where the server listens, where its data lives and the secret that signs the session cookie. It is read from the
## environment, so the same program runs on a laptop and in a container.

import Smtp from "smtp"
import URI from "std/uri"

## The host and the port when the environment says nothing: only this machine, on a port that is free in most setups.
## The port is text, like the variable that it stands for, so `parse` can take it as a default.
export DEFAULT_HOST = "127.0.0.1"
export DEFAULT_PORT = "3000"

## The folder for the files of the app (the database now, the uploads later), relative to where the program runs.
export DEFAULT_DATA_DIR = "data"

## The shortest session secret, the size of the SHA-256 digest that signs the cookie (Bond refuses a shorter one).
MIN_SECRET_BYTES = 32

## Cookies are `Secure` only when the environment says so, since a browser drops them on plain HTTP (a laptop).
export DEFAULT_SECURE_COOKIES = "false"

## The plain port that a `smtp+plain://` url uses when it names none (a mail catcher on this machine).
PLAIN_SMTP_PORT = 25

## The form of `CAMPFIRE_SMTP_URL`, which the errors tell instead of the url: it holds the password.
SMTP_URL_FORM = (
  "smtp://user:password@host:587 (smtps:// for TLS from the first byte, smtp+plain:// for this machine only)"
)

## The address to listen on, the data folder and the url of the database. Port 0 asks the system for a free port (the
## specs use it). `session_secret` signs the session cookie and has no default, since a default is a secret that
## everyone knows; a `Config` must never be printed or logged, for it holds that secret. `secure_cookies` is for an
## app behind HTTPS. `smtp` is how to send email, or `none` when `CAMPFIRE_SMTP_URL` is not set; it holds the SMTP
## password, so it is as secret as the session secret.
export struct Config
  host: String
  port: Int
  data_dir: String
  database_url: String
  session_secret: String
  secure_cookies: Bool
  smtp: Optional[Smtp.Options]
end

struct SmtpLogin
  name: String
  password: String
end

struct SmtpPlace
  host: String
  port: Optional[Int]
end

## The `Config` of `CAMPFIRE_HOST`, `CAMPFIRE_PORT`, `CAMPFIRE_DATA_DIR`, `CAMPFIRE_DATABASE_URL`,
## `CAMPFIRE_SESSION_SECRET`, `CAMPFIRE_SECURE_COOKIES` and `CAMPFIRE_SMTP_URL`, with the defaults for a variable that
## is not set (the secret has none, and without the url there is no email). An `error` says which value is wrong.
export def load() -> Result[Config]
  host = System.env("CAMPFIRE_HOST").unwrap_or(DEFAULT_HOST)
  port = System.env("CAMPFIRE_PORT").unwrap_or(DEFAULT_PORT)
  data_dir = System.env("CAMPFIRE_DATA_DIR").unwrap_or(DEFAULT_DATA_DIR)
  database_url = System.env("CAMPFIRE_DATABASE_URL").unwrap_or("")
  secret = System.env("CAMPFIRE_SESSION_SECRET").unwrap_or("")
  secure_cookies = System.env("CAMPFIRE_SECURE_COOKIES").unwrap_or(DEFAULT_SECURE_COOKIES)
  smtp_url = System.env("CAMPFIRE_SMTP_URL").unwrap_or("")
  return parse(host, port, data_dir, database_url, secret, secure_cookies, smtp_url)
end

## A `Config` from the text of a host, a port, a data folder, a database url, a session secret and the secure cookies
## flag, each the default when left out: an `error` for an empty host or data folder, a data folder with a `?`, a port
## that is not a number from 0 to 65535, a secret of less than 32 bytes (the default, an empty one, is that) and a flag
## that is not `true` or `false`. An empty `database_url` means the file `campfire.db` in the data folder, with the
## FTS5 check on, so that a SQLite without FTS5 stops the start with a clear message. An empty `smtp_url` means no
## email; otherwise it is `smtp://user:password@host:587` (STARTTLS, which the server must offer), `smtps://` (TLS from
## the first byte, port 465 by default) or `smtp+plain://` (no TLS, for a host on this machine only), with the user and
## the password percent-encoded and both left out for a server without login. The `error` for a bad url never has it.
export def parse(
  host: String = DEFAULT_HOST,
  port: String = DEFAULT_PORT,
  data_dir: String = DEFAULT_DATA_DIR,
  database_url: String = "",
  session_secret: String = "",
  secure_cookies: String = DEFAULT_SECURE_COOKIES,
  smtp_url: String = "",
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

  smtp = try parse_smtp_url(smtp_url)
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
      smtp: smtp,
    ),
  )
end

# The url is split by hand: std has no url parser. The user and the password are percent-decoded, so a password with
# an `@` or a `:` goes in as `%40` or `%3A`. The error text never holds the url.
def parse_smtp_url(smtp_url: String) -> Result[Optional[Smtp.Options]]
  text = smtp_url.strip
  if text.empty?
    return ok(none)
  end

  marker = text.index_of("://").unwrap_or(-1)
  if marker < 0
    return error("CAMPFIRE_SMTP_URL must look like #{SMTP_URL_FORM}")
  end

  scheme = text.slice(0, marker)
  authority = text.slice(marker + 3, text.length - marker - 3)
  if authority.end_with?("/")
    authority = authority.slice(0, authority.length - 1)
  end

  if authority.include?("/") or authority.include?("?") or authority.include?("#")
    return error("CAMPFIRE_SMTP_URL has a path, a query or a fragment, which it does not take: #{SMTP_URL_FORM}")
  end

  pieces = authority.split("@")
  place = pieces.last
  login = pieces.take(pieces.size - 1).join("@")
  user = try smtp_login(login)
  address = try smtp_place(place)
  security = try smtp_security(scheme)
  port = address.port.unwrap_or(smtp_default_port(security))
  if address.host.empty?
    return error("CAMPFIRE_SMTP_URL has no host: #{SMTP_URL_FORM}")
  end

  if security == Smtp.Security.Plain and not Smtp.loopback?(address.host)
    return error("CAMPFIRE_SMTP_URL: smtp+plain:// is only for a host on this machine, which sends no password safely")
  end

  return ok(
    some(
      Smtp.Options(host: address.host, port: port, security: security, username: user.name, password: user.password),
    ),
  )
end

def smtp_security(scheme: String) -> Result[Smtp.Security]
  case scheme
    "smtp" -> return ok(Smtp.Security.Starttls)
    "smtps" -> return ok(Smtp.Security.Implicit)
    "smtp+plain" -> return ok(Smtp.Security.Plain)
    _ -> return error("CAMPFIRE_SMTP_URL must start with smtp://, smtps:// or smtp+plain://")
  end
end

def smtp_default_port(security: Smtp.Security) -> Int
  case security
    Smtp.Security.Starttls -> return Smtp.STARTTLS_PORT
    Smtp.Security.Implicit -> return Smtp.IMPLICIT_TLS_PORT
    Smtp.Security.Plain -> return PLAIN_SMTP_PORT
  end
end

# `user:password`, `user` or nothing, each part percent-encoded.
def smtp_login(login: String) -> Result[SmtpLogin]
  colon = login.index_of(":").unwrap_or(-1)
  name = login
  password = ""
  if colon >= 0
    name = login.slice(0, colon)
    password = login.slice(colon + 1, login.length - colon - 1)
  end

  decoded_name = try smtp_decode(name)
  decoded_password = try smtp_decode(password)
  if decoded_name.empty? and not decoded_password.empty?
    return error("CAMPFIRE_SMTP_URL has a password without a user")
  end

  return ok(SmtpLogin(name: decoded_name, password: decoded_password))
end

def smtp_decode(text: String) -> Result[String]
  decoded = URI.decode_uri_component(text)
  if not decoded.ok?
    return error("CAMPFIRE_SMTP_URL has a user or password that is not percent-encoded correctly")
  end

  return decoded
end

# `host`, `host:port`, `[::1]` or `[::1]:port`. The brackets stay on the host, as `Smtp` takes it.
def smtp_place(place: String) -> Result[SmtpPlace]
  host = place
  port_text = ""
  if place.start_with?("[")
    close = place.index_of("]").unwrap_or(-1)
    if close < 0
      return error("CAMPFIRE_SMTP_URL has a [ without a ]")
    end

    host = place.slice(0, close + 1)
    rest = place.slice(close + 1, place.length - close - 1)
    if rest.start_with?(":")
      port_text = rest.slice(1, rest.length - 1)
    elsif not rest.empty?
      return error("CAMPFIRE_SMTP_URL has text after the address in brackets")
    end
  else
    parts = place.split(":")
    if parts.size > 2
      return error("CAMPFIRE_SMTP_URL has more than one colon in the host (an IPv6 address goes in brackets)")
    end

    host = parts[0]
    if parts.size == 2
      port_text = parts[1]
    end
  end

  if port_text.empty?
    return ok(SmtpPlace(host: host, port: none))
  end

  number = port_text.to_i
  if not number.ok? or number.unwrap! < 1 or number.unwrap! > 65535
    return error("CAMPFIRE_SMTP_URL has a port that is not a number from 1 to 65535")
  end

  return ok(SmtpPlace(host: host, port: some(number.unwrap!)))
end

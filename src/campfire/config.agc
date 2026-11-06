## Where the server listens, where its data lives and the secret that signs the session cookie. It is read from the
## environment, so the same program runs on a laptop and in a container.

import Smtp from "mail/smtp"
import URI from "std/uri"

## The host and the port when the environment says nothing: only this machine, on a port that is free in most setups.
## The port is text, like the variable that it stands for, so `parse` can take it as a default.
export DEFAULT_HOST = "127.0.0.1"
export DEFAULT_PORT = "3000"

## The folder for the files of the app (the database now, the uploads later), relative to where the program runs.
export DEFAULT_DATA_DIR = "data"

## The folder of the stylesheet that every page links (`Routes.STYLESHEET` names a file in it), relative to where the
## program runs, which is the folder of the repository for `make run`.
export DEFAULT_ASSETS_DIR = "public/assets"

## The shortest session secret, the size of the SHA-256 digest that signs the cookie (Bond refuses a shorter one).
MIN_SECRET_BYTES = 32

## Cookies are `Secure` only when the environment says so, since a browser drops them on plain HTTP (a laptop).
export DEFAULT_SECURE_COOKIES = "false"

## The connections of the pool when `CAMPFIRE_DB_POOL_SIZE` is not set: 0 takes the size of the database (4 for SQLite).
export DEFAULT_DB_POOL_SIZE = 0

## The fewest connections that `CAMPFIRE_DB_POOL_SIZE` may ask for, when it is not 0. Hashing a password runs while the
## request holds its connection, and the web side lets `AuthWeb.MAX_HASHES` (2) hashes run at once, so a pool that small
## could be held entirely by sign-ins of strangers. One more keeps a connection for everything else.
export MIN_DB_POOL_SIZE = 3

## The most connections `CAMPFIRE_DB_POOL_SIZE` may ask for.
export MAX_DB_POOL_SIZE = 64

## How long a request waits for a free connection when `CAMPFIRE_DB_CHECKOUT_MS` is not set. A request that waits longer
## is answered 503: the server is busy, and a person would rather retry than stare at a spinner.
export DEFAULT_DB_CHECKOUT_MS = 3_000

## The most that `CAMPFIRE_DB_CHECKOUT_MS` may ask for.
export MAX_DB_CHECKOUT_MS = 60_000

## The megabytes of the cache of rendered messages when `CAMPFIRE_CACHE_MB` is not set; 0 turns the cache off. A message
## takes about a kilobyte, so this holds tens of thousands of them.
export DEFAULT_CACHE_MB = 64

## The most that `CAMPFIRE_CACHE_MB` may ask for (4 GiB).
export MAX_CACHE_MB = 4096

## The megabytes of the cache of whole pages (the room page and the older messages) when `CAMPFIRE_RESPONSE_CACHE_MB`
## is not set, the name and the default of the Rails Campfire setting; 0 turns the cache off. A page of a room is about
## 16 KB, so this holds a few thousand.
export DEFAULT_RESPONSE_CACHE_MB = 64

## The most that `CAMPFIRE_RESPONSE_CACHE_MB` may ask for (4 GiB).
export MAX_RESPONSE_CACHE_MB = 4096

## How many emails wait for the mail server when `CAMPFIRE_MAIL_QUEUE_SIZE` is not set.
export DEFAULT_MAIL_QUEUE = 32

## The most emails that may wait for the mail server (`CAMPFIRE_MAIL_QUEUE_SIZE` and `Mailer.start` both refuse more).
export MAX_MAIL_QUEUE = 1024

## The plain port that a `smtp+plain://` url uses when it names none (a mail catcher on this machine).
PLAIN_SMTP_PORT = 25

## The form of `CAMPFIRE_BASE_URL`.
BASE_URL_FORM = "https://campfire.example.com (a scheme, a host and maybe a port)"

## The form of `CAMPFIRE_SMTP_URL`, which the errors tell instead of the url: it holds the password.
SMTP_URL_FORM = (
  "smtp://user:password@host:587 (smtps:// for TLS from the first byte, smtp+plain:// for this machine only)"
)

## The address to listen on, the data folder and the url of the database. Port 0 asks the system for a free port (the
## specs use it). `session_secret` signs the session cookie and has no default, since a default is a secret that
## everyone knows; a `Config` must never be printed or logged, for it holds that secret. `secure_cookies` is for an
## app behind HTTPS. `smtp` is how to send email, or `none` when `CAMPFIRE_SMTP_URL` is not set; it holds the SMTP
## password, so it is as secret as the session secret. `base_url` is the public address of the app without a trailing
## slash (the links in emails start with it), and `mail_from` the sender of those emails: both are empty while `smtp`
## is `none`. `mail_queue` is how many emails may wait to be sent. `db_pool_size` is how many database connections the
## requests share (0: the size the database prefers, else at least `MIN_DB_POOL_SIZE`) and `db_checkout_ms` how long a
## request waits for one. `bcrypt_library` is the library that checks bcrypt digests (see `Bcrypt.verify`): "" is the
## default of the system. It is never checked at start, since a bad one only fails the sign-ins of people with a bcrypt
## digest. `secret_key_base` is the secret of a Rails app, from which the avatar links (`signed_id`) are checked: ""
## (not set) makes every avatar link a 404; it is as secret as the session secret. `storage_dir` is the folder of the
## files of Active Storage (`xx/yy/KEY` inside it, as Rails' Disk service writes them), `DATA_DIR/files` when it is
## not set, and `assets_dir` the folder of the stylesheet. `cache_mb` is the size of the cache of rendered messages in
## megabytes, 0 for none, and `response_cache_mb` the size of the cache of whole pages, 0 for none.
export struct Config
  host: String
  port: Int
  data_dir: String
  database_url: String
  session_secret: String
  secure_cookies: Bool
  smtp: Optional[Smtp.Options]
  base_url: String
  mail_from: String
  mail_queue: Int
  db_pool_size: Int
  db_checkout_ms: Int
  bcrypt_library: String = ""
  secret_key_base: String = ""
  storage_dir: String = ""
  assets_dir: String = DEFAULT_ASSETS_DIR
  cache_mb: Int = DEFAULT_CACHE_MB
  response_cache_mb: Int = DEFAULT_RESPONSE_CACHE_MB
end

# What `CAMPFIRE_SMTP_URL` and its companions make: how to send, and as whom.
struct Mail
  smtp: Optional[Smtp.Options]
  from: String
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
## `CAMPFIRE_SESSION_SECRET`, `CAMPFIRE_SECURE_COOKIES`, `CAMPFIRE_SMTP_URL`, `CAMPFIRE_BASE_URL`, `CAMPFIRE_SMTP_FROM`,
## `CAMPFIRE_SMTP_HOSTNAME`, `CAMPFIRE_BCRYPT_LIBRARY`, `SECRET_KEY_BASE`, `CAMPFIRE_STORAGE_DIR` and
## `CAMPFIRE_ASSETS_DIR`, `CAMPFIRE_CACHE_MB` and `CAMPFIRE_RESPONSE_CACHE_MB`, with the defaults for a variable that
## is not set (the secret has none, and without the smtp url there is no email). An `error` says which value is wrong.
export def load() -> Result[Config]
  host = System.env("CAMPFIRE_HOST").unwrap_or(DEFAULT_HOST)
  port = System.env("CAMPFIRE_PORT").unwrap_or(DEFAULT_PORT)
  data_dir = System.env("CAMPFIRE_DATA_DIR").unwrap_or(DEFAULT_DATA_DIR)
  database_url = System.env("CAMPFIRE_DATABASE_URL").unwrap_or("")
  secret = System.env("CAMPFIRE_SESSION_SECRET").unwrap_or("")
  secure_cookies = System.env("CAMPFIRE_SECURE_COOKIES").unwrap_or(DEFAULT_SECURE_COOKIES)
  smtp_url = System.env("CAMPFIRE_SMTP_URL").unwrap_or("")
  base_url = System.env("CAMPFIRE_BASE_URL").unwrap_or("")
  smtp_from = System.env("CAMPFIRE_SMTP_FROM").unwrap_or("")
  smtp_hostname = System.env("CAMPFIRE_SMTP_HOSTNAME").unwrap_or("")
  mail_queue = System.env("CAMPFIRE_MAIL_QUEUE_SIZE").unwrap_or("")
  db_pool_size = System.env("CAMPFIRE_DB_POOL_SIZE").unwrap_or("")
  db_checkout_ms = System.env("CAMPFIRE_DB_CHECKOUT_MS").unwrap_or("")
  bcrypt_library = System.env("CAMPFIRE_BCRYPT_LIBRARY").unwrap_or("")
  secret_key_base = System.env("SECRET_KEY_BASE").unwrap_or("")
  storage_dir = System.env("CAMPFIRE_STORAGE_DIR").unwrap_or("")
  assets_dir = System.env("CAMPFIRE_ASSETS_DIR").unwrap_or(DEFAULT_ASSETS_DIR)
  cache_mb = System.env("CAMPFIRE_CACHE_MB").unwrap_or("")
  response_cache_mb = System.env("CAMPFIRE_RESPONSE_CACHE_MB").unwrap_or("")
  return parse(
    host,
    port,
    data_dir,
    database_url,
    secret,
    secure_cookies,
    smtp_url,
    base_url,
    smtp_from,
    smtp_hostname,
    mail_queue,
    db_pool_size,
    db_checkout_ms,
    bcrypt_library,
    secret_key_base,
    storage_dir,
    assets_dir,
    cache_mb,
    response_cache_mb,
  )
end

## A `Config` from the text of a host, a port, a data folder, a database url, a session secret and the secure cookies
## flag, each the default when left out: an `error` for an empty host or data folder, a data folder with a `?`, a port
## that is not a number from 0 to 65535, a secret of less than 32 bytes (the default, an empty one, is that) and a flag
## that is not `true` or `false`. An empty `database_url` means the file `campfire.db` in the data folder, with the
## FTS5 check on, so that a SQLite without FTS5 stops the start with a clear message. An empty `smtp_url` means no
## email; otherwise it is `smtp://user:password@host:587` (STARTTLS, which the server must offer; `smtp+starttls://` is
## the same), `smtps://` (TLS from the first byte, port 465 by default) or `smtp+plain://` (no TLS, for a host on this
## machine only), with the user and the password percent-encoded and both left out for a server without login. The
## `error` for a bad url never has it. With a smtp url, `base_url` (`https://campfire.example.com`: a scheme, a host
## and maybe a port, no path) is required, since a link in an email cannot be made from the request that asked for it
## (its `Host` is the visitor's to choose). EHLO says `smtp_hostname`, the host of `base_url` when that is left out,
## and the sender is `smtp_from`, `Campfire <campfire@HOST>` for that host when left out; a host that is an IPv6
## address needs both. `mail_queue` is the number of emails that may wait for the mail server (`DEFAULT_MAIL_QUEUE`
## when left out, at most `MAX_MAIL_QUEUE`): a link that finds the queue full is dropped. `db_pool_size` is the
## number of database connections, 0 or `MIN_DB_POOL_SIZE` to `MAX_DB_POOL_SIZE` (`DEFAULT_DB_POOL_SIZE`, the size of
## the database, when left out), and `db_checkout_ms` how long a request waits for one, 1 to `MAX_DB_CHECKOUT_MS`
## (`DEFAULT_DB_CHECKOUT_MS`). `bcrypt_library` (`CAMPFIRE_BCRYPT_LIBRARY`) is the path or name of a library that
## exports `crypt_r` with bcrypt, for a system without `libcrypt.so.1` (macOS and Windows have none); left out, Linux
## uses `libcrypt.so.1`. `secret_key_base` (`SECRET_KEY_BASE`) is kept as it is; `storage_dir`
## (`CAMPFIRE_STORAGE_DIR`) is `DATA_DIR/files` when left out, and `assets_dir` (`CAMPFIRE_ASSETS_DIR`) must not be
## empty. `cache_mb` (`CAMPFIRE_CACHE_MB`) is the size of the cache of rendered messages, 0 to `MAX_CACHE_MB`
## (`DEFAULT_CACHE_MB` when left out); 0 turns the cache off. `response_cache_mb` (`CAMPFIRE_RESPONSE_CACHE_MB`) is the
## same for the cache of whole pages, 0 to `MAX_RESPONSE_CACHE_MB` (`DEFAULT_RESPONSE_CACHE_MB` when left out).
export def parse(
  host: String = DEFAULT_HOST,
  port: String = DEFAULT_PORT,
  data_dir: String = DEFAULT_DATA_DIR,
  database_url: String = "",
  session_secret: String = "",
  secure_cookies: String = DEFAULT_SECURE_COOKIES,
  smtp_url: String = "",
  base_url: String = "",
  smtp_from: String = "",
  smtp_hostname: String = "",
  mail_queue: String = "",
  db_pool_size: String = "",
  db_checkout_ms: String = "",
  bcrypt_library: String = "",
  secret_key_base: String = "",
  storage_dir: String = "",
  assets_dir: String = DEFAULT_ASSETS_DIR,
  cache_mb: String = "",
  response_cache_mb: String = "",
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

  base = try parse_base_url(base_url)
  if secure_cookies == "true" and base.start_with?("http://")
    return error("CAMPFIRE_BASE_URL must start with https:// when CAMPFIRE_SECURE_COOKIES is true")
  end

  mail = try parse_mail(smtp_url, base, smtp_hostname, smtp_from)
  # The size of a queue that nothing uses is not checked, so a variable left over from a setup with email does not
  # stop the start of one without.
  queue = DEFAULT_MAIL_QUEUE
  if mail.smtp.some?
    queue = try parse_mail_queue(mail_queue)
  end

  size = try parse_db_number("CAMPFIRE_DB_POOL_SIZE", db_pool_size, DEFAULT_DB_POOL_SIZE, 0, MAX_DB_POOL_SIZE)
  if size != 0 and size < MIN_DB_POOL_SIZE
    return error(
      "CAMPFIRE_DB_POOL_SIZE must be 0 (the size of the database) or a number from #{MIN_DB_POOL_SIZE} to " +
      "#{MAX_DB_POOL_SIZE}, not #{db_pool_size.inspect}: a smaller pool could be held entirely by sign-ins that hash",
    )
  end

  checkout = try parse_db_number(
    "CAMPFIRE_DB_CHECKOUT_MS",
    db_checkout_ms,
    DEFAULT_DB_CHECKOUT_MS,
    1,
    MAX_DB_CHECKOUT_MS,
  )

  cache = try parse_db_number("CAMPFIRE_CACHE_MB", cache_mb, DEFAULT_CACHE_MB, 0, MAX_CACHE_MB)
  pages = try parse_db_number(
    "CAMPFIRE_RESPONSE_CACHE_MB",
    response_cache_mb,
    DEFAULT_RESPONSE_CACHE_MB,
    0,
    MAX_RESPONSE_CACHE_MB,
  )

  if assets_dir.strip.empty?
    return error("CAMPFIRE_ASSETS_DIR is empty")
  end

  folder = data_dir.strip
  files = storage_dir.strip
  if files.empty?
    files = "#{folder}/files"
  end

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
      smtp: mail.smtp,
      base_url: base,
      mail_from: mail.from,
      mail_queue: queue,
      db_pool_size: size,
      db_checkout_ms: checkout,
      bcrypt_library: bcrypt_library.strip,
      secret_key_base: secret_key_base,
      storage_dir: files,
      assets_dir: assets_dir.strip,
      cache_mb: cache,
      response_cache_mb: pages,
    ),
  )
end

## True when the links in emails go over plain HTTP to a host that is not this machine: a token that crosses the
## network in the clear. The app says so at start; with secure cookies it is an error of `parse` instead.
export def plain_link?(config: Config) -> Bool
  return config.base_url.start_with?("http://") and not Smtp.loopback?(authority_host(config.base_url))
end

# A whole number of `name` from `low` to `high`, `fallback` when the text is empty.
def parse_db_number(name: String, text: String, fallback: Int, low: Int, high: Int) -> Result[Int]
  if text.strip.empty?
    return ok(fallback)
  end

  number = text.strip.to_i
  if not number.ok? or number.unwrap! < low or number.unwrap! > high
    return error("#{name} must be a number from #{low} to #{high}, not #{text.inspect}")
  end

  return number
end

# The size of the queue of emails, `DEFAULT_MAIL_QUEUE` when it is not set. Only read when email is on.
def parse_mail_queue(text: String) -> Result[Int]
  if text.strip.empty?
    return ok(DEFAULT_MAIL_QUEUE)
  end

  number = text.strip.to_i
  if not number.ok? or number.unwrap! < 1 or number.unwrap! > MAX_MAIL_QUEUE
    return error("CAMPFIRE_MAIL_QUEUE_SIZE must be a number from 1 to #{MAX_MAIL_QUEUE}, not #{text.inspect}")
  end

  return number
end

# `https://campfire.example.com`, or "" when it is not set. Only the origin: a link adds the path.
def parse_base_url(base_url: String) -> Result[String]
  text = base_url.strip
  if text.empty?
    return ok("")
  end

  if not text.start_with?("http://") and not text.start_with?("https://")
    return error("CAMPFIRE_BASE_URL must look like #{BASE_URL_FORM}")
  end

  clean = text
  if clean.end_with?("/")
    clean = clean.slice(0, clean.length - 1)
  end

  marker = clean.index_of("://").unwrap_or(0)
  rest = clean.slice(marker + 3, clean.length - marker - 3)
  if rest.empty? or rest.include?("/") or rest.include?("?") or rest.include?("#") or rest.include?("@")
    return error("CAMPFIRE_BASE_URL must have a host and no user, path, query or fragment: #{BASE_URL_FORM}")
  end

  return ok(clean)
end

# The smtp url with the EHLO name and the sender that go with it. Nothing is needed without the url.
def parse_mail(smtp_url: String, base: String, smtp_hostname: String, smtp_from: String) -> Result[Mail]
  if smtp_url.strip.empty?
    return ok(Mail(smtp: none, from: ""))
  end

  if base.empty?
    return error("CAMPFIRE_BASE_URL is required with CAMPFIRE_SMTP_URL: the links in emails start with it")
  end

  hostname = smtp_hostname.strip
  if hostname.empty?
    hostname = base_host(base)
  end

  if hostname.empty? or hostname.include?(" ") or hostname.bytes.to_a.any? do |byte| byte < 33 or byte > 126 end
    return error("CAMPFIRE_SMTP_HOSTNAME must be set to a host name (the host of CAMPFIRE_BASE_URL cannot be used)")
  end

  from = smtp_from.strip
  if from.empty?
    from = "Campfire <campfire@#{hostname}>"
  end

  smtp = try parse_smtp_url(smtp_url, hostname)
  return ok(Mail(smtp: some(smtp), from: from))
end

# The host of the base url for EHLO: no port, and "" for an IPv6 address in brackets, which EHLO writes another way.
def base_host(base: String) -> String
  host = authority_host(base)
  if host.start_with?("[")
    return ""
  end

  return host
end

# The host of the base url as a URL writes it: no port, the brackets of an IPv6 address kept.
def authority_host(base: String) -> String
  marker = base.index_of("://").unwrap_or(0)
  authority = base.slice(marker + 3, base.length - marker - 3)
  if authority.start_with?("[")
    return authority.slice(0, authority.index_of("]").unwrap_or(authority.length - 1) + 1)
  end

  return authority.split(":")[0]
end

# The url is split by hand: std has no url parser. The user and the password are percent-decoded, so a password with
# an `@` or a `:` goes in as `%40` or `%3A`. The error text never holds the url.
def parse_smtp_url(smtp_url: String, local_hostname: String) -> Result[Smtp.Options]
  text = smtp_url.strip

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
    Smtp.Options(
      host: address.host,
      local_hostname: local_hostname,
      port: port,
      security: security,
      username: user.name,
      password: user.password,
    ),
  )
end

def smtp_security(scheme: String) -> Result[Smtp.Security]
  case scheme
    "smtp" -> return ok(Smtp.Security.Starttls)
    "smtp+starttls" -> return ok(Smtp.Security.Starttls)
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

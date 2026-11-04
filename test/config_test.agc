import AuthWeb from "../src/campfire_web/auth"
import Config from "../src/campfire/config"
import Smtp from "../src/campfire/mail/smtp"

SECRET = "0123456789abcdef0123456789abcdef"

# `parse` with the defaults for the address and the folder, to test the secret and the flag.
def secret_and_flag(secret: String, secure_cookies: String) -> Result[Config.Config]
  return Config.parse(Config.DEFAULT_HOST, Config.DEFAULT_PORT, Config.DEFAULT_DATA_DIR, "", secret, secure_cookies)
end

# `parse` with the defaults for what a test does not name, and a good secret.
def parse(host: String, port: String, data_dir: String) -> Result[Config.Config]
  return Config.parse(host, port, data_dir, "", SECRET)
end

# The `Config` that a smtp url makes with the public address `https://chat.example.com`, or its error.
def mail_of(url: String) -> Result[Config.Config]
  return mail_with(url, "https://chat.example.com", "", "")
end

def mail_with(url: String, base_url: String, from: String, hostname: String) -> Result[Config.Config]
  return Config.parse(
    Config.DEFAULT_HOST,
    Config.DEFAULT_PORT,
    Config.DEFAULT_DATA_DIR,
    "",
    SECRET,
    "false",
    url,
    base_url,
    from,
    hostname,
  )
end

# The `smtp` of the `Config` that a url makes, or the error of the url.
def smtp_of(url: String) -> Result[Optional[Smtp.Options]]
  config = try mail_of(url)
  return ok(config.smtp)
end

# `parse` with email on (or off, for an empty url) and this size of the queue of emails.
def mail_queue_of(url: String, size: String) -> Result[Config.Config]
  base_url = ""
  if not url.empty?
    base_url = "https://chat.example.com"
  end

  return Config.parse(
    Config.DEFAULT_HOST,
    Config.DEFAULT_PORT,
    Config.DEFAULT_DATA_DIR,
    "",
    SECRET,
    "false",
    url,
    base_url,
    "",
    "",
    size,
  )
end

# `parse` with this size of the database pool and this wait for a connection.
def pool_of(size: String, checkout: String) -> Result[Config.Config]
  return Config.parse(
    Config.DEFAULT_HOST,
    Config.DEFAULT_PORT,
    Config.DEFAULT_DATA_DIR,
    "",
    SECRET,
    "false",
    "",
    "",
    "",
    "",
    "",
    size,
    checkout,
  )
end

def main() -> Void
  Test.run([
    Test.test("a host and a port make a config, and the database is a file of the data folder by default") do
      Test.eq(
        Config.parse(" 0.0.0.0 ", " 8080 ", " var/campfire ", "", SECRET, "true"),
        ok(
          Config.Config(
            host: "0.0.0.0",
            port: 8080,
            data_dir: "var/campfire",
            database_url: "sqlite:var/campfire/campfire.db?fts5=required",
            session_secret: SECRET,
            secure_cookies: true,
            smtp: none,
            base_url: "",
            mail_from: "",
            mail_queue: 32,
            db_pool_size: 0,
            db_checkout_ms: 3_000,
          ),
        ),
      )
    end,
    Test.test("what is left out is the default") do
      Test.eq(
        secret_and_flag(SECRET, Config.DEFAULT_SECURE_COOKIES),
        ok(
          Config.Config(
            host: Config.DEFAULT_HOST,
            port: 3000,
            data_dir: Config.DEFAULT_DATA_DIR,
            database_url: "sqlite:data/campfire.db?fts5=required",
            session_secret: SECRET,
            secure_cookies: false,
            smtp: none,
            base_url: "",
            mail_from: "",
            mail_queue: 32,
            db_pool_size: 0,
            db_checkout_ms: 3_000,
          ),
        ),
      )
    end,
    Test.test("a database url is kept as it is") do
      Test.eq(
        Config.parse(Config.DEFAULT_HOST, "0", Config.DEFAULT_DATA_DIR, " sqlite:/srv/chat.db ", SECRET),
        ok(
          Config.Config(
            host: Config.DEFAULT_HOST,
            port: 0,
            data_dir: "data",
            database_url: "sqlite:/srv/chat.db",
            session_secret: SECRET,
            secure_cookies: false,
            smtp: none,
            base_url: "",
            mail_from: "",
            mail_queue: 32,
            db_pool_size: 0,
            db_checkout_ms: 3_000,
          ),
        ),
      )
    end,
    Test.test("a port that is not a number from 0 to 65535 is an error") do
      try Test.error?(parse("127.0.0.1", "http", Config.DEFAULT_DATA_DIR))
      try Test.error?(parse("127.0.0.1", "65536", Config.DEFAULT_DATA_DIR))
      try Test.error?(parse("127.0.0.1", "-1", Config.DEFAULT_DATA_DIR))
      Test.error?(parse("127.0.0.1", "", Config.DEFAULT_DATA_DIR))
    end,
    Test.test("an empty host, an empty data folder or a data folder with a ? is an error") do
      try Test.error?(parse("  ", Config.DEFAULT_PORT, Config.DEFAULT_DATA_DIR))
      try Test.error?(parse("127.0.0.1", "3000", "tmp/a?b"))
      Test.error?(parse("127.0.0.1", "3000", " "))
    end,
    Test.test("a session secret of less than 32 bytes, or none, is an error") do
      try Test.error?(Config.parse())
      try Test.error?(secret_and_flag("0123456789abcdef0123456789abcde", "false"))
      Test.ok?(secret_and_flag(SECRET, "false"))
    end,
    Test.test("the secure cookies flag is true or false") do
      try Test.error?(secret_and_flag(SECRET, "yes"))
      Test.ok?(secret_and_flag(SECRET, "true"))
    end,
    Test.test("no CAMPFIRE_SMTP_URL means no email") do Test.eq(smtp_of(""), ok(none)) end,
    Test.test("a smtp url has the user and the password percent-decoded, and each scheme has its default port") do
      try Test.eq(
        smtp_of("smtp://ana%40example.com:p%3Aw%2Fd@mail.example.com:2587"),
        ok(
          some(
            Smtp.Options(
              host: "mail.example.com",
              local_hostname: "chat.example.com",
              port: 2587,
              security: Smtp.Security.Starttls,
              username: "ana@example.com",
              password: "p:w/d",
            ),
          ),
        ),
      )

      try Test.eq(
        smtp_of("smtps://mail.example.com/"),
        ok(
          some(
            Smtp.Options(
              host: "mail.example.com",
              local_hostname: "chat.example.com",
              port: 465,
              security: Smtp.Security.Implicit,
            ),
          ),
        ),
      )

      try Test.eq(smtp_of("smtp+starttls://mail.example.com"), smtp_of("smtp://mail.example.com"))
      try Test.eq(
        smtp_of("smtp://mail.example.com"),
        ok(
          some(
            Smtp.Options(
              host: "mail.example.com",
              local_hostname: "chat.example.com",
              port: 587,
              security: Smtp.Security.Starttls,
            ),
          ),
        ),
      )

      Test.eq(
        smtp_of("smtp+plain://[::1]:1025"),
        ok(
          some(
            Smtp.Options(host: "[::1]", local_hostname: "chat.example.com", port: 1025, security: Smtp.Security.Plain),
          ),
        ),
      )
    end,
    Test.test("a bad smtp url is an error that does not show the url, and plain is only for this machine") do
      try Test.error?(smtp_of("mail.example.com"))
      try Test.error?(smtp_of("http://mail.example.com"))
      try Test.error?(smtp_of("smtp://mail.example.com:99999"))
      try Test.error?(smtp_of("smtp://:secret@mail.example.com"))
      try Test.error?(smtp_of("smtp://a:b@mail.example.com/inbox"))
      try Test.error?(smtp_of("smtp+plain://mail.example.com:25"))
      try Test.error?(smtp_of("smtp+plain://127.0.0.1.example.com"))
      shown = smtp_of("smtp://ana:hunter2@mail.example.com:abc").message
      Test.eq(shown.include?("hunter2") or shown.include?("ana"), false)
    end,
    Test.test("the public address, the sender and the EHLO name come from the base url unless they are set") do
      config = mail_of("smtp://mail.example.com").unwrap!
      try Test.eq(config.base_url, "https://chat.example.com")
      try Test.eq(config.mail_from, "Campfire <campfire@chat.example.com>")
      try Test.eq(config.smtp.unwrap!.local_hostname, "chat.example.com")
      named = mail_with("smtp://mail.example.com", "http://localhost:3000/", "Chat <chat@acme.test>", "mx.acme.test")
      try Test.eq(named.unwrap!.base_url, "http://localhost:3000")
      try Test.eq(named.unwrap!.mail_from, "Chat <chat@acme.test>")
      try Test.eq(named.unwrap!.smtp.unwrap!.local_hostname, "mx.acme.test")
      # Without email the address is optional and nothing about the sender is kept.
      try Test.eq(mail_with("", "", "", "").unwrap!.mail_from, "")
      Test.eq(mail_with("", "https://chat.example.com", "", "").unwrap!.mail_from, "")
    end,
    Test.test("email needs a base url that is only an origin, and a host name that EHLO can say") do
      try Test.error?(mail_with("smtp://mail.example.com", "", "", ""))
      try Test.error?(mail_with("smtp://mail.example.com", "chat.example.com", "", ""))
      try Test.error?(mail_with("smtp://mail.example.com", "https://chat.example.com/app", "", ""))
      try Test.error?(mail_with("smtp://mail.example.com", "https://user@chat.example.com", "", ""))
      try Test.error?(mail_with("", "ftp://chat.example.com", "", ""))
      try Test.error?(mail_with("smtp://mail.example.com", "https://[::1]:3000", "", ""))
      try Test.ok?(mail_with("smtp://mail.example.com", "https://[::1]:3000", "Chat <chat@acme.test>", "acme.test"))
      Test.error?(mail_with("smtp://mail.example.com", "https://chat.example.com", "", "two words"))
    end,
    Test.test(
      "a base url on plain HTTP is a warning for a host that is not this machine, and an error with secure cookies",
    ) do
      plain = mail_with("smtp://mail.example.com", "http://chat.example.com", "", "").unwrap!
      try Test.eq(Config.plain_link?(plain), true)
      for base in ["http://localhost:3000", "http://127.0.0.1", "http://[::1]:3000", "https://chat.example.com"]
        named = mail_with("smtp://mail.example.com", base, "Chat <chat@acme.test>", "acme.test").unwrap!
        try Test.eq(Config.plain_link?(named), false)
      end

      secure = Config.parse(
        Config.DEFAULT_HOST,
        Config.DEFAULT_PORT,
        Config.DEFAULT_DATA_DIR,
        "",
        SECRET,
        "true",
        "",
        "http://chat.example.com",
      )

      try Test.error?(secure)
      Test.ok?(Config.parse(Config.DEFAULT_HOST, "3000", "data", "", SECRET, "true", "", "https://chat.example.com"))
    end,
    Test.test("the queue of emails has a default size unless the environment says another, up to the most") do
      mail = "smtp://mail.example.com"
      try Test.eq(mail_queue_of(mail, "").unwrap!.mail_queue, Config.DEFAULT_MAIL_QUEUE)
      try Test.eq(mail_queue_of(mail, " 5 ").unwrap!.mail_queue, 5)
      try Test.error?(mail_queue_of(mail, "0"))
      try Test.error?(mail_queue_of(mail, "#{Config.MAX_MAIL_QUEUE + 1}"))
      try Test.error?(mail_queue_of(mail, "many"))
      # With email off nothing uses the queue, so its size is not checked.
      Test.eq(mail_queue_of("", "many").unwrap!.mail_queue, Config.DEFAULT_MAIL_QUEUE)
    end,
    Test.test("the pool has a default size and wait unless the environment says another, within limits") do
      defaults = pool_of("", "").unwrap!
      try Test.eq(defaults.db_pool_size, Config.DEFAULT_DB_POOL_SIZE)
      try Test.eq(defaults.db_checkout_ms, Config.DEFAULT_DB_CHECKOUT_MS)
      chosen = pool_of(" 4 ", " 250 ").unwrap!
      try Test.eq(chosen.db_pool_size, 4)
      try Test.eq(chosen.db_checkout_ms, 250)
      try Test.error?(pool_of("-1", ""))
      try Test.error?(pool_of("1", ""))
      try Test.error?(pool_of("#{Config.MIN_DB_POOL_SIZE - 1}", ""))
      try Test.ok?(pool_of("#{Config.MIN_DB_POOL_SIZE}", ""))
      try Test.assert(Config.MIN_DB_POOL_SIZE > AuthWeb.MAX_HASHES, "a pool could be held by the hashing slots")
      try Test.error?(pool_of("#{Config.MAX_DB_POOL_SIZE + 1}", ""))
      try Test.error?(pool_of("", "0"))
      try Test.error?(pool_of("", "#{Config.MAX_DB_CHECKOUT_MS + 1}"))
      Test.error?(pool_of("many", ""))
    end,
    Test.test(
      "the bcrypt library is empty (the default of the system) unless the environment names one, and is never checked",
    ) do
      try Test.eq(parse("127.0.0.1", "3000", "data").unwrap!.bcrypt_library, "")
      named = Config.parse(
        Config.DEFAULT_HOST,
        Config.DEFAULT_PORT,
        Config.DEFAULT_DATA_DIR,
        "",
        SECRET,
        "false",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        " /nonexistent/libcrypt.so ",
      )

      Test.eq(named.unwrap!.bcrypt_library, "/nonexistent/libcrypt.so")
    end,
  ])
end

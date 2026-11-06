# Security

What the app promises and what it does not do yet. Rules for changing the code are in
[AGENTS.md](../AGENTS.md).

## Sessions

The cookie is `session_token` (as in Rails Campfire) and holds a random token that is checked against
the `sessions` table. It lasts 30 days and is `HttpOnly` with `SameSite=Lax`;
`CAMPFIRE_SECURE_COOKIES=true` adds `Secure` and renames it `__Host-session_token`, so a browser only
takes it from the host itself (see [configuration.md](configuration.md)). The sign-in form posts
`email_address` and `password` to `/session` and a good sign-in answers `302`. (The first-run, join
and password-reset forms still call their field `email`.)

Signing out deletes the row, so a copy of the cookie stops working. So do deactivating a person
and resetting their password, which delete every session of that person (a deactivation deletes their reset links too).

A session row keeps the address of the client that made it and `last_active_at`, which is written
at most every five minutes. Starting a session deletes the rows older than the cookie life (30
days) and the rows of a deactivated person. The address is the peer of the connection: behind a
proxy it is the proxy's, because the app does not trust `X-Forwarded-For`.

Forms are protected against other sites with Bond's `Sec-Fetch-Site` and `Origin` check, with no
token: a post with `Sec-Fetch-Site: same-origin` or `none` passes, `same-site` and `cross-site` get
`403`, and a request with neither header and no `Origin` (a tool such as `curl` or the Rails benchmark
harness, which sends only `Sec-Fetch-Site: same-origin`) passes too.

## Passwords

Passwords are stored as scrypt digests (cost 2^16, block size 8, two lanes, a random salt each, in
the form `scrypt$N$r$p$salt$key`) and are never logged. A new password is at least 8 characters,
on first run, join and reset.

A database that came from a Rails Campfire has bcrypt digests (`$2a$12$...`, also `$2b$` and
`$2y$`). Sign-in checks them next to scrypt ones, through the FFI to `crypt_r` of a libcrypt that has
bcrypt. The library is `libcrypt.so.1` of libxcrypt on Linux (Debian 10, Ubuntu 18.10, Fedora 29,
RHEL 8 and later), or whatever `CAMPFIRE_BCRYPT_LIBRARY` names: macOS has no bcrypt in its libc and
Windows has no `crypt`, so there the variable must name a libxcrypt build (its path, for example
`/opt/homebrew/opt/libxcrypt/lib/libcrypt.1.dylib`). The check runs on the compute pool, so it does not
hold a scheduler, and a cost of 12 takes about a quarter of a second. Nothing makes a bcrypt digest
and a sign-in does not rewrite one: a password that is set or reset is scrypt. Notes:

- The library is opened when a digest is checked, not at start-up, so a missing library, a path
  that is wrong, a library with no `crypt_r` or one without bcrypt does not stop the app. It fails
  the sign-in of a person with a bcrypt digest with `500` (not "wrong password": the answer
  does not depend on the password) and a log line that names the cause and `CAMPFIRE_BCRYPT_LIBRARY`.
  Accounts with scrypt digests are not affected, and a person can get an scrypt digest by resetting
  the password.
- Only a digest of exactly the bcrypt shape reaches the library. bcrypt reads the first 72 bytes of a
  password, so a longer one that starts the same signs in (as in Rails). A password with a NUL byte, or
  over 256 bytes, never matches, but it costs a real check of a fixed password against the same digest,
  so its time is that of a wrong password.
- A digest with a cost above 15 (a quarter of a second at 12, doubling each step) is an error, not a
  hash of minutes, and the limit is fixed: that person cannot sign in until their password is reset
  (or the cost of the digest is lowered in the database). The log line says so.
- A sign-in for an email that has no account takes the time of an scrypt hash (about a second); one for
  a bcrypt account takes the quarter second of its cost. A person who can time requests can tell the
  two apart, so an imported database shows which of its emails exist. The `500` of a cost over the
  limit and the `500` of a library that cannot be used say the same: this email has a bcrypt account.

At most two passwords are hashed at the same time (each scrypt takes about a second and 64 MiB; a
bcrypt check counts as one too). A sign-in, first-run, join or reset form that arrives while both slots
are busy is answered `503` with `Retry-After`.

## Which pages need a sign-in

Every page does, except the sign-in, first-run and password-reset pages, `/health`, `/up`,
`/join/CODE` and what is under `/assets/` (the stylesheet). The list is deny-by-default: a new route is private until
`src/campfire_web/auth.agc` names it.

A person only sees a room they are a member of. A closed or direct room of other people and a room
that does not exist answer the same `404 Not Found`, and a message posted to one is refused the
same way before its text is looked at.

## Signed ids

`src/campfire/signed_id.agc` makes and checks the tokens that Rails writes with
`record.signed_id(purpose: ...)`, such as the avatar link `/users/TOKEN/avatar` of upstream
Campfire, from `SECRET_KEY_BASE`. The format is Rails 7.1 to 8.0's: a PBKDF2-HMAC-SHA256 key (1000
iterations, the salt `active_record/signed_id`, 64 bytes), an HMAC-SHA256 over the URL-safe base64 of
`{"_rails":{"data":ID,"pur":"user/avatar"}}`, joined by `--`. `SignedId.verify` checks the signature
in constant time before it decodes anything, then the purpose and the expiry, and answers an id or
nothing, never why. The token is readable by anyone (it is signed, not encrypted), so it is only a
way to name a user, never a proof of who is asking. `GET /users/TOKEN/avatar` uses it, with the key of
`SECRET_KEY_BASE`: a token that does not verify, for another purpose, expired or for no user is the
same `404` as a missing page. The picture is sent `Cache-Control: private` (Rails says `public`), since
the route needs a sign-in and a shared cache must not hand it to anyone else.

## Message bodies

Message bodies are stored as sanitized HTML (`HtmlSanitizer.sanitize`), cleaned when they are read
as well (a row that Rails wrote was never cleaned by this app; markup that is clean already comes
out unchanged), and shown with `<%==` as element content only.

## The first administrator

Whoever reaches `/first_run` first becomes the administrator, so make the account before the app
is reachable by anyone else.

## The join code

The code (`a1b2-c3d4-e5f6`) is 48 random bits. A wrong code, an old one of a regenerated code
included, answers the `404` of a page that does not exist. The pages that show the code are
`no-store` with `Referrer-Policy: no-referrer`. Regenerate the link when it is no longer wanted;
the old one stops working at once.

## Email addresses

Pages that ask for an email answer the same for every address, so they cannot be used to find out
who is registered. The work behind the password reset differs by a few queries, which a timing
measurement could in principle tell apart.

The exception is sign-up on the join page: it tells a person whose email has an account
to sign in instead (a deactivated person's address was renamed, so it is free), and only whoever holds the link can ask.

## Deactivation and open requests

A deactivation takes effect on the next request: the sign-in filter looks the person up once per request and the
handler uses that answer, so a request that has passed the filter (or waits for a database connection) still runs.
The people and join-code changes re-check inside their transaction that the actor is an active administrator, and
posting a message needs an active person (the insert itself checks). The other writes of rooms do not check the actor again, so a
request that was already past the filter finishes.

## Known gaps

- A double click or a retry of a message post stores two messages: there is no dedupe on `client_message_id`
  (Rails has none either), and the page does not check it yet.
- The per-IP limit covers sign-in only (the post to `/session`). The join page, the first run and the
  password reset form have none: the join code is 48 random bits, and the password reset has its own
  limits (see [mail.md](mail.md)).
- Since Agentica 0.24.0 scrypt runs on the compute pool, so a hash does not block a scheduler. The
  limit of two hashes at a time still applies, since each one takes 64 MiB.

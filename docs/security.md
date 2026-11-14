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
and resetting their password, which delete every session of that person (a deactivation deletes their reset
links too).

A person who is signed in can make a link that signs another device in as them (the profile page, `POST
/session/transfers`), shown with its QR code on a `no-store` page. Rails signs the user id and lets the link work for 4
hours, as often as it is opened; here the token is 32 random bytes, works once and for 15 minutes, and only its SHA-256
is kept, in memory (a restart ends every link). A person has one link at a time: a new one ends the last. A link works
only while the session that made it lasts, so signing out, a password reset, a deactivation and a ban end it too.
Opening the link only shows a button (a page that no other site may frame), so a link preview or a scanner does not use
it up; the button (`PUT`, checked against other sites like any form) signs in, and a used, expired, replaced or unknown
link, or one of a person who is no longer active, is `400`. The link starts with
`CAMPFIRE_BASE_URL` when it is set (see the bots API below for the fallback). `GET /qr_code/ID` draws any Base64url text
of up to 213 bytes, as Rails does, but only for a person who is signed in (drawing costs some CPU); the app does not link
it, since a URL with a token in it would reach logs and caches.

A session row keeps the address of the client that made it and `last_active_at`, which is written at
most every five minutes (a read of a page that the cache keeps does not write it, so on a quiet
database it can be older). A row older than the cookie life (30 days) is refused whatever the cookie says,
also for a person that the page cache keeps (it keeps the end of the session with them), and starting a
session deletes it, with the rows of a deactivated person. The address is the peer of the connection:
behind a proxy it is the proxy's, because the app does not trust `X-Forwarded-For`.

Forms are protected against other sites with Bond's `Sec-Fetch-Site` and `Origin` check, with no
token: a post with `Sec-Fetch-Site: same-origin` or `none` passes, `same-site` and `cross-site` get
`403`, and a request with neither header and no `Origin` (a tool such as `curl` or the Rails benchmark
harness, which sends only `Sec-Fetch-Site: same-origin`) passes too. Over plain HTTP a browser sends no
`Sec-Fetch-Site` (only a secure origin gets it), so the check falls to `Origin`: it passes when the host of the
`Origin` is the `Host` of the request, which works behind a proxy that keeps `Host`. `Origin: null` means the browser
hid the origin (a form on a page sent with `Referrer-Policy: no-referrer` does that, and so does a sandboxed frame); it
is refused, so the private pages send `Referrer-Policy: same-origin`, which keeps their tokens and codes out of the
`Referer` of any other site and lets a form carry the real `Origin`. The one exception is the messages API of the chat
bots (`/rooms/ID/KEY/messages`, see [people.md](people.md#the-messages-api)): the key in the path is the whole login and
no cookie is read, so a page of another site has nothing to forge with, and Rails lets a request with a bot key skip
the check as well. The two headers are taken off such a request before the check; the browser routes (a path like
`/rooms/1//messages` included) keep it.

The key is stored as plain text, as in Rails, and is compared with the stored one in constant time. It is in the URL, so
the answers of the API are `Cache-Control: no-store`, and a reverse proxy or any log that records paths records keys:
turn path logging off for `/rooms/*/*/messages` there, or treat the log as a secret. A key that names no active bot is
`404`, and so is a room that the bot is not in. Requests with a wrong key are not rate limited, as in Rails; a token
has 62^12 values.

The links in the answers of the API (`url`, `Location`, `Link`) and the curl lines of the bots page start with
`CAMPFIRE_BASE_URL`. Set it behind a proxy: without it they start with the scheme of the app (`https` only with
`CAMPFIRE_SECURE_COOKIES=true`) and the `Host` of the request, which a proxy may change, and a `Host` that is not a host
name or address with a port is left out, so the links are paths.

## Webhooks

An administrator may give a bot a webhook URL, which the app posts messages to from the server (see
[people.md](people.md#webhooks)). Rails does not check where it points. Here every address that the host resolves to
must be on the open internet (the rule of the bans: no loopback, private, shared, link-local, documentation or reserved
address, and for IPv6 only `2000::/3`), or nothing is sent and the log says why; `CAMPFIRE_WEBHOOK_PRIVATE_ADDRESSES=true`
turns the check off. The check resolves the host before the post, which resolves it again, so a name whose DNS answer
changes in between can still reach a private address: give a bot a URL on a host you trust (`std/http` cannot connect
to an address that was checked yet: agentica-lang/agentica#1556). Redirects are not followed. A post waits at most
`CAMPFIRE_WEBHOOK_TIMEOUT` seconds and reads at most 1 MiB of the answer; at most 32 run at once (4 for one bot) and
256 wait, and a post past that is dropped and logged. A message of a bot (the API) goes to no webhook, so bots cannot loop.

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
`/join/CODE`, what is under `/assets/` (the stylesheet), and the manifest, the service worker and the icon of the
installable app (`/webmanifest.json`, `/service-worker.js`, `/account/logo`) and a sign-in link
(`/session/transfers/TOKEN`). The list is deny-by-default: a new route is private until
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
out unchanged), and shown with `<%==` as element content only. A body longer than
`CAMPFIRE_MAX_MESSAGE_LENGTH` is refused before the sanitizer reads it, so the work of one message is
bounded (the sanitizer reads up to about 5 times the cap for a form's text, which is made HTML first). A form says
that its body is HTML with `message[format]=html`; the body is cleaned the same way, so the field adds no markup that a
bot could not send already. The links that `Autolink.link` makes are written from the clean body only: an address is
text up to a space, a `<` or a `"`, inside a double-quoted `href`, so it cannot leave the attribute (the clean text has
no `<` or `>`, and an entity that it keeps, such as `&quot;`, is harmless inside an attribute); only `http://`,
`https://` and `www.` start one, and it carries `rel="noopener noreferrer"`.

## Attachments

A file of a message (`docs/rooms.md`) is at most `CAMPFIRE_MAX_ATTACHMENT_MB` (`413` while it arrives, before the
handler runs). Bond receives it in a private folder under a name of its own; the stored name is the last part of what
the client sent, with control characters taken out, and the file goes to `xx/yy/KEY`, so no client text is ever a
path. The type that is stored comes from the first bytes (PNG, JPEG, GIF, WebP, PDF) and else from the extension, never
from the client; an extension of one of those types on other bytes is `application/octet-stream`. A download is for the
people of the room, checked on every request (no signed link that outlives a membership; `private, no-cache`). An image
is shown inline only when its bytes are of its stored type; anything else is `Content-Disposition: attachment`, and HTML,
SVG, XML and scripts are sent as `application/octet-stream`. Every answer has `X-Content-Type-Options: nosniff`,
`Content-Security-Policy: default-src 'none'; sandbox` and `Cross-Origin-Resource-Policy: same-origin`.
Only a `POST` of a message may send `multipart/form-data`: any other is `415` before its body is read, and the start
empties the folder of the uploads. There is no upload quota or rate limit per person, as in Rails.
The name that the client sent is untrusted: it is kept only after Bond's `safe_filename` and escaped wherever it is shown.
A preview decodes nothing on the server: the size of an image is read from its header, and the page shows the image
itself (a link to the same route) only up to 250 million pixels (Rails' `THUMBNAIL_MAX_PIXELS`), so a small file that
is a huge picture is a download link and no browser is asked to decode it. A video is played from the same download
answer, which a `<video>` takes as it is.

## The first administrator

Whoever reaches `/first_run` first becomes the administrator, so make the account before the app
is reachable by anyone else.

## The join code

The code (`a1b2-c3d4-e5f6`) is 48 random bits. A wrong code, an old one of a regenerated code
included, answers the `404` of a page that does not exist. The pages that show the code are
`no-store` with `Referrer-Policy: same-origin`. Regenerate the link when it is no longer wanted;
the old one stops working at once.

## Email addresses

Pages that ask for an email answer the same for every address, so they cannot be used to find out
who is registered. The work behind the password reset differs by a few queries, which a timing
measurement could in principle tell apart.

The exception is sign-up on the join page: it tells a person whose email has an account
to sign in instead (a deactivated person's address was renamed, so it is free), and only whoever holds the link
can ask.

## Bans

A request that is not a `GET` or a `HEAD` from an address that a ban holds gets `429` before the sign-in check, so a
banned person cannot sign in again from where they were, and cannot post. The address is the peer of the connection
(`Conn.remote_addr`), not `X-Forwarded-For`, which a client chooses. A flag in memory says whether any ban exists, so
a write costs no query when there is none; it is read from the table at the first write and kept by the ban and the
unban of the app.

Behind a reverse proxy every request comes from the proxy. Only addresses of the open internet are written
(`Bans.public_address?`: IPv4 outside the loopback, private, shared, documentation, multicast and reserved ranges, and
IPv6 only inside `2000::/3`, as an allowlist, minus the documentation and reserved prefixes), so a proxy on the same
host, a LAN, Docker or Tailscale is safe: no ban holds its address and the IP ban does nothing there (the ban still
ends the sessions, closes the sockets and removes the messages). A proxy on a **public** address is not safe. The app
sees the proxy's address, `public_address?` accepts it, and one ban of a person whose session came through it writes
it. After that every write from everybody gets `429`, the sign-in included, and so does the post that lifts the ban:
anyone who shares a banned address, an administrator too, cannot unban from it. The only way out is to delete the row
by hand (see below), so do not run the app behind a public proxy until it reads `X-Forwarded-For` from a trusted
proxy.

A person who shares an address with someone who was banned (an office, a mobile network) gets `429` on every write.
The way out is to lift the ban from the person's page (which deletes all of their rows) from another address, or to
delete the row by hand, for example `delete from bans where ip_address = '198.51.100.7'`, which takes effect at once.
A row added by hand while no ban exists is seen after a restart, when the flag is read again.

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

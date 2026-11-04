# Security

What the app promises and what it does not do yet. Rules for changing the code are in
[AGENTS.md](../AGENTS.md).

## Sessions

The cookie holds a random token that is checked against the `sessions` table. It lasts 30 days and
is `HttpOnly` with `SameSite=Lax`; `CAMPFIRE_SECURE_COOKIES=true` adds `Secure` and the `__Host-`
prefix (see [configuration.md](configuration.md)).

Signing out deletes the row, so a copy of the cookie stops working. So do deactivating a person
and resetting their password, which delete every session of that person.

A session row keeps the address of the client that made it and `last_active_at`, which is written
at most every five minutes. Starting a session deletes the rows older than the cookie life (30
days) and the rows of a deactivated person. The address is the peer of the connection: behind a
proxy it is the proxy's, because the app does not trust `X-Forwarded-For`.

Forms are protected against other sites with Bond's `Sec-Fetch-Site` and `Origin` check, with no
token.

## Passwords

Passwords are stored as scrypt digests (cost 2^16, block size 8, two lanes, a random salt each, in
the form `scrypt$N$r$p$salt$key`) and are never logged. A new password is at least 8 characters,
on first run, join and reset.

Sign-in is limited per client address: the 11th post to `/session` within 3 minutes of the first
(right or wrong, as in upstream Campfire) is answered `429` with `Retry-After`, before the form is
read, whatever way the path is written. The count is kept in memory, so a restart clears it. An IPv6
client counts by its /64 prefix. Behind a proxy every visitor shares the proxy's address and so one
limit, and a request whose address is unknown shares one limit too. The windows are fixed, not
sliding: a client can make 10 attempts at the end of one window and 10 more at the start of the
next, so 20 attempts in a few seconds. The table holds at most 100,000 entries (a client in a window
takes 2 to 3, so about 33,000 clients; about 30 MB when full). An entry stays until the first sweep
after its window and the next one have ended, so 2 to 3 windows (6 to 9 minutes); a sweep runs only
when an attempt arrives. While the table is full, the addresses that are not in it share one
overflow client with 10 times the limit (100 attempts in 3 minutes), so a flood of addresses cannot
grow the memory and cannot refuse every new person outright; the addresses in the table keep their
own counts. If the flood uses up that shared limit, a new address is answered `429` with `Retry-After`
set to the seconds until the overflow window ends (at most 180), which is also when the
shared count starts again.

At most two passwords are hashed at the same time (each takes about a second and 64 MiB). A
sign-in, first-run, join or reset form that arrives while both slots are busy is answered `503`
with `Retry-After`.

## Which pages need a sign-in

Every page does, except the sign-in, first-run and password-reset pages, `/health` and
`/join/CODE`. The list is deny-by-default: a new route is private until
`src/campfire_web/auth.agc` names it.

A person only sees a room they are a member of. A closed or direct room of other people and a room
that does not exist answer the same `404 Not Found`, and a message posted to one is refused the
same way before its text is looked at.

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

The exception is sign-up on the join page: it tells a person whose email has an account (a
deactivated person's too) to sign in instead, and only whoever holds the link can ask.

## Known gaps

- The per-IP limit covers sign-in only (the post to `/session`). The join page, the first run and the
  password reset form have none: the join code is 48 random bits, and the password reset has its own
  limits (see [mail.md](mail.md)).
- Hashing a password blocks a scheduler on Agentica 0.23.0. Agentica main fixes it
  ([agentica#1052](https://github.com/agentica-lang/agentica/pull/1052)), in the next release. The
  limit of two hashes at a time still applies.

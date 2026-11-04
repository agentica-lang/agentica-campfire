# Security

What the app promises and what it does not do yet. Rules for changing the code are in
[AGENTS.md](../AGENTS.md).

## Sessions

The cookie holds a random token that is checked against the `sessions` table. It lasts 30 days and
is `HttpOnly` with `SameSite=Lax`; `CAMPFIRE_SECURE_COOKIES=true` adds `Secure` and the `__Host-`
prefix (see [configuration.md](configuration.md)).

Signing out deletes the row, so a copy of the cookie stops working. So do deactivating a person
and resetting their password, which delete every session of that person.

Forms are protected against other sites with Bond's `Sec-Fetch-Site` and `Origin` check, with no
token.

## Passwords

Passwords are stored as scrypt digests (cost 2^16, block size 8, two lanes, a random salt each, in
the form `scrypt$N$r$p$salt$key`) and are never logged. A new password is at least 8 characters,
on first run, join and reset.

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

- There is no per-IP rate limit on sign-in or the join page. It is not built yet: it needs a Bond
  pin bump (Bond has the client address now) plus the filter
  ([agentica-campfire#9](https://github.com/agentica-lang/agentica-campfire/issues/9)). The
  password reset has its own limits (see [mail.md](mail.md)).
- Hashing a password blocks a scheduler on Agentica 0.23.0. Agentica main fixes it
  ([agentica#1052](https://github.com/agentica-lang/agentica/pull/1052)), in the next release. The
  limit of two hashes at a time still applies.

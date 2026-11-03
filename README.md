# agentica-campfire

Group chat written in [Agentica](https://github.com/agentica-lang/agentica): a port of 37signals' [ONCE Campfire](https://github.com/basecamp/once-campfire), built on [Bond](https://github.com/agentica-lang/bond), EAG templates and [agentica-db](https://github.com/agentica-lang/agentica-db).

This is an independent project. It is not affiliated with or endorsed by 37signals. Campfire is MIT licensed (copyright 37signals, LLC). Any CSS, JavaScript or images reused from it keep that copyright and license notice, and the notice is added to this repository when the first file is copied.

Status: a skeleton with a database and sign-in. A Bond server on a SQLite database whose schema (accounts, users, sessions, rooms, memberships, messages, boosts, attachments, webhooks and the message search index) is created by numbered migrations at start-up. On the first run there is no account, so every page sends the visitor to a setup form that makes the first user, an administrator; after that people sign in with an email and a password, and sign out. The home page needs a sign-in; `GET /health` does not. See [docs/plan.md](docs/plan.md) for what Agentica, Bond and agentica-db still need, the MVP and the phases.

## Run

Needs [Agentica](https://github.com/agentica-lang/agentica) 0.23.0 or later on `PATH`.

```sh
make install   # fetch Bond and agentica-db (pinned by commit in agentica.toml) into deps/
CAMPFIRE_SESSION_SECRET=$(openssl rand -hex 32) make run   # http://127.0.0.1:3000/
```

Open the address: the app has no account yet, so it shows the setup form (your name, an email and a password of at least 8 characters). That makes the administrator and signs you in. Whoever reaches `/first_run` first becomes the administrator, so do the setup before the app is reachable by anyone else: it listens on `127.0.0.1` by default, and `CAMPFIRE_HOST` should stay that way (or sit behind a firewall or a proxy that only you can reach) until the account exists.

`CAMPFIRE_SESSION_SECRET` is required, at least 32 bytes, and has no default: it signs the session cookie, so keep it out of the repository and the image, and use the same value on every start (a new one signs everybody out). Behind HTTPS set `CAMPFIRE_SECURE_COOKIES=true`, which makes the cookie `Secure` with the `__Host-` prefix (a browser then refuses it over plain HTTP). The cookie holds a random token that is checked against the `sessions` table, lasts 30 days and is `HttpOnly` with `SameSite=Lax`; signing out deletes the row, so a copy of the cookie stops working. Passwords are stored as scrypt digests (cost 2^16, block size 8, two lanes, a random salt each, in the form `scrypt$N$r$p$salt$key`) and never logged. At most two passwords are hashed at the same time (each takes about a second and 64 MiB); a sign-in or first-run form that arrives while both are busy is answered `503` with `Retry-After`. There is no per-IP rate limit yet (it needs the client address in Bond, [bond#46](https://github.com/agentica-lang/bond/issues/46)), and the hashing blocks a scheduler until [agentica#1049](https://github.com/agentica-lang/agentica/issues/1049). The first line of output says whether the cookie is `Secure`. Forms are protected against other sites with Bond's `Sec-Fetch-Site` and `Origin` check, with no token.

`CAMPFIRE_SMTP_URL` says how to send email (nothing uses it yet; the password reset will): `smtp://user:password@host:587` (or `smtp+starttls://`) sends over STARTTLS and refuses to send unless the server offers it, `smtps://user:password@host:465` uses TLS from the first byte, and `smtp+plain://host:1025` uses no TLS and is only accepted for a host on this machine (a mail catcher in development). The user and the password are percent-encoded (`%40` for `@`), both are left out for a server without login, and the password is never logged or shown in an error. Unset means no email. The code is `src/smtp.agc` (`Smtp.send(message, options)` for one message, `Smtp.connect`, `Smtp.send_message` and `Smtp.quit` for several on one connection) and `src/smtp_message.agc` (the message: headers, UTF-8 subject, text or text and HTML); they import nothing else of the app, so they can move to a package of their own.

`CAMPFIRE_HOST` and `CAMPFIRE_PORT` change where it listens (`CAMPFIRE_PORT=0` picks a free port, and the last line of output says which). `GET /health` answers `{"schema_version":10,"status":"ok"}`.

The app keeps its files in `CAMPFIRE_DATA_DIR` (`data/` by default, no `?` in it). Start-up makes the folder and the parents that are missing with mode 0700 (the database holds password digests and tokens, and SQLite makes the file with the umask), and leaves a folder that exists as it is. The database is `sqlite:DATA_DIR/campfire.db?fts5=required` unless `CAMPFIRE_DATABASE_URL` says another [agentica-db SQLite url](https://agentica-lang.github.io/agentica-db/guide/sqlite/) (WAL mode and foreign keys are on by default; add `fts5=required` to stop at start-up when the system SQLite has no FTS5, which message search needs). At start-up the app runs the migrations that the database has not seen (`src/migrations.agc`) and prints `database: schema version N, migrations applied: M`; if the database cannot be opened or migrated it exits with code 1 and a message that names the variable. Run one instance at a time per database: migrations run from one process, and two started together make one of them fail on `schema_migrations`. A url with `foreign_keys=off` is refused at start-up, since the schema relies on cascades. Back up with `VACUUM INTO`, or copy the file after the app stops: while it runs, recent writes may live in the `-wal` file.

## Develop

The tests are BDD first: `specs/auth.feature`, `specs/session_config.feature`, `specs/home.feature` and `specs/database.feature` start the app on 127.0.0.1 and a free port, with a fresh database and a session secret of their own, and talk to it over HTTP with a small browser that keeps cookies (`specs/http_steps.agc`); `specs/schema.feature` checks the rules of the schema (foreign keys, unique values, the search index) through SQL steps; `test/` has unit tests of the config, the password hashing, the hashing limit and the layout. Hashing a password takes about a second at this cost, so the suite takes under a minute.

```sh
make check
make test
```

CI (`.github/workflows/ci.yml`) pins the Agentica release with its sha256.

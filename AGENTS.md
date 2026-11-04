# agentica-campfire

A port of ONCE Campfire (group chat) in Agentica, on Bond.
`README.md` has what it is and how to run it; `docs/` has the behavior
(configuration, security, rooms, people, mail) and `docs/plan.md` the plan and the phases.

## Map

```text
campfire.agc    the program (`make run`): config from the environment, the data folder, then the app
src/campfire/   the domain: it knows nothing about HTTP or Bond
                config.agc (host, port, data folder, database url, session secret), data_dir.agc (the
                private data folder), slots.agc (a limit on concurrent hashes), rate_limit.agc (attempts per
                key in a window, for the per-IP sign-in limit), passwords.agc (scrypt, and the check of bcrypt digests),
                bcrypt.agc (bcrypt digests of a Rails Campfire, checked through FFI to the system libcrypt),
                signed_id.agc (Rails `signed_id` tokens from `SECRET_KEY_BASE`),
                accounts.agc (the join code and the people: deactivate and reactivate, over SQL), auth.agc
                (first run, the join link, sign in, sign out and password reset, over SQL), rooms.agc (open,
                closed and direct rooms, memberships and messages over SQL), html_sanitizer.agc (an allowlist
                sanitizer for stored HTML bodies; pure)
src/campfire/repo/   database.agc (migrate, the pool, `with_connection` for a request), migrations.agc (the list of the
                schema) and migrations/ (one file per migration, `m0001_accounts.agc`...), rails.agc (the integer
                enums and the timestamp form of the Rails schema), rows.agc (reading a column of a row)
src/campfire/mail/   mailer.agc (the task that sends email off the request path), smtp.agc and
                smtp_message.agc (sending email: the client and the message builder; they import no other
                app module, so they can move to their own package)
src/campfire_web/    HTTP, on Bond: app.agc (start: database, pool, then server), web.agc (the routes), failure.agc (the 500 and
                the 503 of a failure), routes.agc
                (the paths), views.agc (EAG templates, the reset email too), auth.agc (cookie sessions,
                CSRF, the sign-in filter, the routes of first run, the join link, sign in, sign out and
                password reset), accounts.agc (the people page and those posts), rooms.agc (the routes
                and forms of rooms)
specs/          BDD: *.feature, steps.agc (the app and the database), http_steps.agc (a browser with
                cookies), smtp_steps.agc (an SMTP client against a peer), mail_steps.agc (the peer as the
                mail server of the app: reads its email, follows the link), fixtures/server.agc (the app, from
                the environment that the steps set), fixtures/smtp_peer.agc (a hermetic SMTP server that writes
                down the dialogue; its test CA and certificate are in fixtures/tls, made by make-certs.sh),
                fixtures/rails/ (campfire.sqlite3: a database that a real Rails Campfire made from its db/schema.rb;
                `make.sh` makes it again in a ruby container)
test/           unit tests (*_test.agc)
docs/           what the app does, one file per topic; plan.md is the plan and the phases
agentica.toml   the manifest; Bond is pinned by tag, agentica-db by commit (`pool` comes with it), agentica.lock has their hashes
```

## Commands

- `make install` fetches `deps/` from the lock (git ignores `deps/`). `make check`, `make fmt-check`, `make test`,
  `make run`.
- `make run` needs `CAMPFIRE_SESSION_SECRET` (32 bytes or more, from the environment, never committed; the
  specs draw their own).
- Agentica 0.23.0 or later. CI pins it with its sha256 (`AGENTICA_VERSION`, `AGENTICA_SHA256` in
  `.github/workflows/ci.yml`).
- To move Bond or agentica-db: `agentica add bond https://github.com/agentica-lang/bond --ref COMMIT` (or `db`
  and `https://github.com/agentica-lang/agentica-db`), commit the lock.

## Rules

- Layers: `src/campfire/` (the domain: config, accounts, auth, rooms, passwords, `repo/`, `mail/`) never imports
  `src/campfire_web/`, Bond (`pkg/bond/...`) or `std/http`, and never names `Bond.Conn`, `HttpRequest` or any other HTTP
  type. `src/campfire_web/` calls the domain, never the reverse; a piece that needs HTTP or Bond is web, a piece that
  needs neither belongs to the domain. Imports are relative to the importing file (`../campfire/rooms` from the web
  side, `repo/rows` inside the domain).
- BDD first: a behavior is a Gherkin scenario in `specs/` before the code. A test over HTTP uses 127.0.0.1 and port 0.
  Unit tests (`test/`) only for pure helpers. A scenario gives the app its settings with `the environment variable`
  steps (`CAMPFIRE_*`), never through stdin, and a step that makes something on disk registers its removal with
  `BDD.after`, so a failed scenario leaves nothing behind.
- Views are EAG templates with `<%@ escape &Bond.escape %>` as the first line, so every `<%= %>` is escaped. The one
  exception is a plain-text email (`Views.reset_mail`): nothing in it is HTML, so it has no escape directive.
  `<%== %>` only for markup that the program wrote, never for a value of a client.
- `agentica.toml` has `blank_line_after_end = true`: every bare `end` is followed by an empty line.
- The schema is the Rails one (`db/schema.rb` of basecamp/once-campfire at 90b3300): every table that Rails has is made
  as Rails writes it, column names, types, indexes and keys included (migrations 1 to 14), and `specs/schema.feature`
  compares them with a database that Rails made (`specs/fixtures/rails/`), the virtual FTS5 table too. The one table of
  the app that Rails has not, `password_resets`, is the last migration; it lives in the list so that a database the app
  makes has it in its history, and `Migrations.extensions()` hands the same `if not exists` statements to a database
  that Rails made. Keys are Rails': no cascade, and no key where Rails has none (`memberships`, `rooms.creator_id`).
  `users.role` and `users.status` are integers and `rooms.type` is `Rooms::Open|Closed|Direct` (`repo/rails.agc` names
  them: never write a bare number or type string in SQL of `src/`; `Rooms.OPEN`, `CLOSED` and `DIRECT` are the types,
  and `Rooms.ADMINISTRATOR_ROLE_NAME` is the label of the role, not the integer), and timestamps are `Rails.NOW` text with
  no default in the table, so every insert sets `created_at` and `updated_at`.
  A database with `ar_internal_metadata` was made by Rails and is opened as it is (`Database.migrate`, after a check
  of the columns the app reads, `needed_columns`: add a column there when the app starts to read it): no migration
  runs on it, and the one thing added is `Migrations.extensions()`. The app never makes `ar_internal_metadata` or
  `schema_migrations`: its history is `agentica_schema_migrations`.
- Migrations are one file per migration in `src/campfire/repo/migrations/`, `mNNNN_name.agc` exporting `migration()`,
  listed in order in `migrations.agc` (`test/migrations_test.agc` catches a file missing from the list). There has been
  no release, so the history is rewritten, with the checksums in `specs/schema.feature`, until the first release; from
  then on never edit one that has shipped (`Migrate` refuses it on a database that ran it)
  and add the next number.
- A message is three rows written in one transaction (`Rooms.post`): `messages`, its body in `action_text_rich_texts`
  (`record_type` `Message`, `name` `body`, HTML cleaned by `HtmlSanitizer.sanitize`) and its plain text in the
  standalone FTS5 table `message_search_index` with the message id as `rowid`. There are no triggers, so whatever
  writes or deletes a message writes or deletes the other two. Never write `insert or replace into messages`. Page a
  room by `created_at` and then `id` (`Rooms.page`), as Rails does: the id of a database that Rails seeded does not
  follow time. There is no unique index on `client_message_id` (Rails has none), so the app does not drop a repeat.
- Auth: a page is public only if `PUBLIC_PATHS` in `src/campfire_web/auth.agc` names it (the sign-in filter is
  deny-by-default); the one exception is `/join/CODE` (`AuthWeb.public?`: exactly `/join/` and one segment), since its
  code is part of the path and cannot be a fixed entry, and the handler answers a wrong code with the 404 of any
  missing page (`Routes.MISSING`, the one 404 text of every handler and of the app for a path with no route). A
  request takes one connection of the pool for its work (`Database.with_connection(pool)`, which is `DbPool.with`: the
  app starts the pool once in `App.start`, in the task of `main`, and hands it to the routes). The sign-in filter looks
  the person up and keeps them with `Bond.assign`; a handler reads them with `AuthWeb.assigned_user` and does not look
  them up again. The block runs in a task of the pool, not in the task of the request. A wait for a connection that runs
  out (`CAMPFIRE_DB_CHECKOUT_MS`), or a statement over its `timeout_ms`, is answered 503 with `Retry-After` by the
  `Bond.on_error` of `Web.build` (`Failure.answer`, `Database.busy?`; also for a full queue, a closing pool and SQLite error 5). A `sqlite::memory:` database is not usable by the app (one
  empty database per connection). Hashing runs while the request holds its connection (at most `AuthWeb.MAX_HASHES` at a time), so `CAMPFIRE_DB_POOL_SIZE` is 0 or at least `Config.MIN_DB_POOL_SIZE` (3). Never log or store a plain password; a form that is shown again never holds the password.
  The sign-in form posts `email_address` (as Rails Campfire does) and the cookie is `session_token`
  (`__Host-session_token` with secure cookies); `/up` is public and answers the green page of Rails. A bcrypt digest
  (`$2a$`, `$2b$`, `$2y$`) is checked by `Bcrypt.verify` through `crypt_r` on the compute pool, never made. The library
  is `libcrypt.so.1` on Linux or `CAMPFIRE_BCRYPT_LIBRARY` (`Config.bcrypt_library`), opened by name with `dlopen` (or
  `LoadLibrary`) when a digest is checked, and `crypt_r` is called through the address it gives: never name a libcrypt
  function in an `extern` block, since a missing one stops the program, where a missing library or symbol must be an
  `error`. Only after `Bcrypt.digest?` has checked the shape and the password has no NUL (a NUL in a C string stops the
  program) does anything reach C. A system without bcrypt is an `error`, which fails the request and names the
  variable, not a wrong password, and never stops the app. It takes a hashing slot like scrypt.
  Sign-in is limited per client address (`RateLimit.hit`, called first in `AuthWeb.create_session` and not by a
  path-matching filter, since the router also takes `/session/` there: 10 posts in 3 minutes, then 429 with
  `Retry-After`, before the form is read; an IPv6 client counts by its /64); the address is `Conn.remote_addr`, which Bond
  does not take from `X-Forwarded-For`. A session row keeps it (`ip_address`); `last_active_at` is written at most
  every 5 minutes, in `Auth.user_for`, and starting a session purges the rows past the cookie life and those of a
  deactivated person (`purge_sessions`).
- Invitation: `Auth.join` makes a member for `/join/CODE` (the form's own path) and calls `Rooms.grant_open_rooms` in
  the transaction that makes the user; the code, the form and the email are checked before a hashing slot is taken (a
  form that cannot work takes no slot), and the code and the email again inside the transaction, so a regenerated code
  refuses a form that was open and two forms with one email make one person. Joining never reactivates a deactivated
  person (their email counts as taken). Everything of `Accounts` that changes something (`deactivate`, `reactivate`,
  `regenerate_join_code`) checks inside its transaction that the actor is an active administrator, and an
  administrator cannot deactivate themselves; deactivating deletes the person's sessions and reset links, and
  reactivating calls `Rooms.grant_open_rooms`. A session is opened with one insert that reads `status` itself
  (`open_session`), so a sign-in that races a deactivation leaves no row for a reactivation to revive. The pages with
  the join code are `no-store` and `no-referrer`. Sign-up is the deliberate exception to "a page that asks for an
  email answers the same for every address": it answers 422 for an email that has an account (why: `docs/security.md`).
- Email: the app never sends from a request: it calls `Mailer.enqueue`, which does not wait and does not fail. A
  link in an email starts with `config.base_url`, never with the `Host` of the request. A page that asks for an email
  answers the same for every address (no enumeration). A reset token is stored as a hash only. The write
  transactions of the reset (`Db.transaction`, which begins with `BEGIN IMMEDIATE`) are what make concurrent requests
  send one email and change a password once; there is no app-level lock, since agentica-db waits for a busy database
  by sleeping in the task, for at most its `busy_timeout` (5 s by default). A wait that runs out is a database error,
  so the request answers 500.
- Rooms: a person is in a room only by a `memberships` row, for every kind; every lookup for a person goes through it
  (`Rooms.find`), so a room of other people and a room that does not exist answer the same `404 Not Found`, and the
  membership check comes before anything about the room or the posted form is looked at (a 422 would tell that the room
  exists). Whatever makes a user after the open rooms exist (the invitation), and whatever reactivates one (`status`
  deactivated to active, who has missed the rooms made meanwhile), calls `Rooms.grant_open_rooms`; whatever makes an open room puts
  every active person in it (`Rooms.create_open`); a closed room has only the chosen active people and its maker
  (`Rooms.create_closed`), and a direct room is found by its exact set of people before one is made
  (`Rooms.open_direct`), in one transaction (the people are checked as active inside it, so the search counts who
  is inserted). The settings form carries `was`, the people in the room when it was drawn, and an update applies only
  its diff (the chosen that are not in `was` are added, `was` minus the chosen is taken out), so a stale form neither
  takes out someone added since nor brings back someone taken out; the sender is never offered. The settings of a room
  exist for a closed room only, and for any other room the person is in they are the same 404. Only the maker and an
  account administrator may change a closed room (`Rooms.editable?`): another member is answered 403, after the
  membership check (a non-member is 404) and before the form is read; `Rooms.update_closed` checks it again inside its
  transaction and fails, rolling back, when it no longer holds. The form sends plain text, stripped of the space around
  it, which the web layer turns into HTML (`HtmlSanitizer.from_text`) for `Rooms.post`; the view writes a body only as
  `Rooms.page` gives it, cleaned again.
- HTML bodies: markup that did not come from a view is shown only after `HtmlSanitizer.sanitize` (it writes tags
  from its own allowlist and nothing else of the input but text and the checked `href` of a link), and then
  with `<%== %>`, as element content only: `'` and `"` are not escaped, so the output never goes inside an
  attribute or a script. A change to its lists adds a case to `test/html_sanitizer_test.agc`, an XSS one for a new
  tag or attribute.
- No Dockerfile or assets yet: each is a later PR of `docs/plan.md` phase 2.
- Campfire's CSS, JS and images are MIT (37signals): keep their notice when a file is copied (see README).
- Code comments say why. Follow `agentica-programming` and `agentica-code-guidelines` for the style.

# agentica-campfire

A port of ONCE Campfire (group chat) in Agentica, on Bond.
`README.md` has what it is and the quick start; `docs/` has the behavior
(configuration, security, rooms, people, mail, docker, benchmarks) and `docs/plan.md` the plan and the phases.

## Map

```text
campfire.agc    the program (`make run`): config from the environment, the data folder, then the app
src/campfire/   the domain: it knows nothing about HTTP or Bond
                config.agc (host, port, data folder, database url, session secret, `SECRET_KEY_BASE`, the storage and assets
                folders), data_dir.agc (the private data folder), slots.agc (a limit on concurrent hashes), rate_limit.agc (attempts per
                key in a window, for the per-IP sign-in limit), passwords.agc (scrypt, and the check of bcrypt digests),
                bcrypt.agc (bcrypt digests of a Rails Campfire, checked through FFI to the system libcrypt),
                signed_id.agc (Rails `signed_id` tokens from `SECRET_KEY_BASE`),
                accounts.agc (the join code and the people: deactivate and reactivate, over SQL), profiles.agc (the user
                page and the profile save, over SQL), bots.agc (the chat bots: make, rename, new key, deactivate, over
                SQL), bans.agc (ban and unban, the check of an address, over SQL), boosts.agc (the reactions under a message,
                over SQL),
                auth.agc
                (first run, the join link, sign in, sign out and password reset, over SQL), rooms.agc (open,
                closed and direct rooms, memberships and messages over SQL), presence.agc (who is connected to which room,
                in memory), searches.agc (the words of a query, the
                FTS5 search of messages, the recent searches), avatars.agc (the Active Storage variant of an avatar
                and its file; initials and colour), html_sanitizer.agc (an allowlist sanitizer for stored HTML
                bodies; pure), autolink.agc (the links of URLs and email addresses in a clean body, made when a
                message is shown; pure)
src/campfire/repo/   database.agc (migrate, the pool, `with_connection` for a request, the observer),
                version_reader.agc (the read of `PRAGMA data_version` on a connection of its own, without the pool),
                migrations.agc (the list of the schema) and migrations/ (one file per migration, `m0001_accounts.agc`...),
                rails.agc (the integer enums and the timestamp form of the Rails schema), rows.agc (reading a column of a
                row)
src/campfire/mail/   mailer.agc (the task that sends email off the request path), smtp.agc and
                smtp_message.agc (sending email: the client and the message builder; they import no other
                app module, so they can move to their own package)
src/campfire_web/    HTTP, on Bond: app.agc (start: database, pool, then server), web.agc (the routes), blocks.agc (`handler`: names a
                `do` block before a pipeline of routes, since a chain after `end` is refused), failure.agc (the 500 and
                the 503 of a failure), routes.agc
                (the paths), views.agc (EAG templates, the reset email too), auth.agc (cookie sessions,
                CSRF, the sign-in filter, the routes of first run, the join link, sign in, sign out and
                password reset), accounts.agc (the people page and those posts), bots.agc (the chat bots pages and
                posts), boosts.agc (the boosts of a message: list, new, add, remove), bot_messages.agc (the messages API of the
                bots, by key, boosts included), profiles.agc (the user page and the profile),
                rooms.agc (the routes
                and forms of rooms), room_deletion.agc (the task that deletes a deleted room's messages),
                content_removal.agc (the task that takes a banned person's messages away), message_cache.agc
                (the cache of rendered messages), page_cache.agc (the cache of whole room pages), sidebars.agc,
                searches.agc and avatars.agc (the sidebar page, the search and the
                avatar link, whose answer is kept in the page store by `PageCache.shared_spot`), cable.agc (`/cable`: the handlers of the channels, the signed stream names of the pages and the
                broadcasts of the routes, on bond-channels)
Dockerfile, docker/entrypoint.sh, docker-compose.yml   the image of the benchmark (`docs/docker.md`): the Rails-style environment to `CAMPFIRE_*`
app/            the sources of the assets: `assets/stylesheets/` (SCSS, `application.scss` only does `@use`; settings, base, layout,
                components, utilities) and `javascript/` (ES modules, `application.js` the entry)
tools/assets.mjs  `make assets`: Dart Sass and esbuild, the fingerprinted files and `src/campfire_web/asset_names.agc`
public/assets/  the built, fingerprinted stylesheet and script (composer, keys, live updates, scroll paging and keeping, local time), committed; served under `/assets/` (`CAMPFIRE_ASSETS_DIR`)
DESIGN.md       the visual design system (tokens, components, states, accessibility); the stylesheet implements it
specs/          BDD: *.feature, steps.agc (the app and the database), http_steps.agc (a browser with
                cookies), cable_steps.agc (WebSocket clients of `/cable` through
                fixtures/ws_client/cable_client.agc, a program of websocket-client with a manifest of its own, so the
                app does not depend on it: a step cannot leave a reader task running), smtp_steps.agc (an SMTP client
                against a peer), mail_steps.agc (the peer as the
                mail server of the app: reads its email, follows the link), fixtures/server.agc (the app, from
                the environment that the steps set), fixtures/smtp_peer.agc (a hermetic SMTP server that writes
                down the dialogue; its test CA and certificate are in fixtures/tls, made by make-certs.sh),
                fixtures/rails/ (campfire.sqlite3: a database that a real Rails Campfire made from its db/schema.rb;
                `make.sh` makes it again in a ruby container)
test/           unit tests (*_test.agc)
tools/          keys_check.js and room_check.js: the by-hand browser checks of the composer keys and of the room page's scroll paging, scroll keeping and local time (playwright-core, not in CI)
bench/          run.sh runs basecamp/once-campfire-verification on the app in a Debian container (README.md there);
                harness.patch is the local patch of the harness (agentica among its apps)
docs/           what the app does, one file per topic; plan.md is the plan and the phases
agentica.toml   the manifest; Bond, agentica-db and bond-channels are pinned by tag (`pool` comes with `db`, which pins it by commit), agentica.lock has their hashes
```

## Commands

- `make install` fetches `deps/` from the lock (git ignores `deps/`). `make check`, `make fmt-check`, `make test`,
  `make run`.
- `make run` needs `CAMPFIRE_SESSION_SECRET` (32 bytes or more, from the environment, never committed; the
  specs draw their own).
- Agentica 0.30.0 or later (`OpenSSL.*` builtins, `T.codec`, `Codec[T]`, Bond 0.11.0 and agentica-db 0.9.0 need it, and a C compiler for the native SQLite driver of agentica-db, built into the package cache on the first run; `make test` runs `agentica test --jobs $(JOBS)`, 4 files at once by default). CI pins it
  with its sha256 (the `version` and `sha256` inputs of `agentica-lang/setup-agentica` in `.github/workflows/ci.yml`;
  bump the `AGENTICA_VERSION` and `AGENTICA_SHA256` ARGs of the `Dockerfile` with them).
- To move Bond, agentica-db or bond-channels: change `tag` in `agentica.toml` and run `agentica update bond` (or `db`, `channels`), commit the lock.
  Keep Bond's tag the one that bond-channels asks for; if they differ, `override = true` on `bond` forces the tag.
  A new dependency is `agentica add NAME URL --tag TAG`.

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
  them: never write a bare number or type string in SQL of `src/`; `Rooms.CLOSED` and `Rooms.DIRECT` are the types the
  rest of the app names (`OPEN` is private to `rooms.agc`), and `Rooms.ADMINISTRATOR_ROLE_NAME` is the label of the
  role, not the integer), and timestamps are `Rails.NOW` text with no default in the table, so every insert sets
  `created_at` and `updated_at`.
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
  follow time. There is no unique index on `client_message_id` (Rails has none), so the app does not drop a repeat. The same
  transaction touches the room and sets `unread_at` (`Room#receive`), and the sanitizing happens before it begins, so
  the write lock that the writers queue on is not held for it. The markup of a message (`Views.message`) is what the
  benchmark of basecamp/once-campfire-verification checks (`specs/message_routes.feature` lists its rules): change it
  only with that feature.
- Auth: a page is public only if `PUBLIC_PATHS` in `src/campfire_web/auth.agc` names it (the sign-in filter is
  deny-by-default); the exceptions are `/join/CODE` (`AuthWeb.public?`: exactly `/join/` and one segment), since its
  code is part of the path and cannot be a fixed entry, and the messages API of the bots (`AuthWeb.bot_api?`, below),
  and the handler answers a wrong code with the 404 of any
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
  every 5 minutes, in `Auth.user_for`, which refuses a row past the cookie life; the person that `PageCache` keeps for a
  version carries the end of the session (`Auth.Session`) and is refused after it, since no commit announces it.
  Starting a session purges those rows and those of a deactivated person (`purge_sessions`).
- Invitation: `Auth.join` makes a member for `/join/CODE` (the form's own path) and calls `Rooms.grant_open_rooms` in
  the transaction that makes the user; the code, the form and the email are checked before a hashing slot is taken (a
  form that cannot work takes no slot), and the code and the email again inside the transaction, so a regenerated code
  refuses a form that was open and two forms with one email make one person. Joining never reactivates a deactivated
  person (a deactivation renames their address with `-deactivated-UUID`, as Rails does, so the address is free).
  Everything of `Accounts` that changes something (`deactivate`, `reactivate`, `regenerate_join_code`) checks inside
  its transaction that the actor is an active administrator, and an administrator cannot deactivate themselves;
  deactivating deletes the person's sessions, reset links, push subscriptions, searches and shared-room memberships
  (`Rooms.leave_shared_rooms`) and renames the address, and reactivating restores the address (`Change.Taken` is a 409
  when another account has it) and calls `Rooms.grant_open_rooms`. A session is opened with one insert that reads
  `status` itself (`open_session`), so a sign-in that races a deactivation leaves no row for a reactivation to revive.
  The pages with the join code are `no-store` and `same-origin` (not `no-referrer`: that makes the browser post
  `Origin: null`, which `Bond.csrf` refuses). Sign-up is the deliberate exception to "a page that asks for an email
  answers the same for every address": it answers 422 for an email that has an account (why: `docs/security.md`).
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
  exist for an open and a closed room, and for a direct room the person is in they are the same 404 (a direct room never
  converts). The form says what the room is to be (`type`; absent keeps it), and `Rooms.update_room` converts it: closed to
  open grants every active person, open to closed applies the diff of the form. Only the maker and an
  account administrator may change an open or closed room (`Rooms.editable?`): another member is answered 403, after the
  membership check (a non-member is 404) and before the form is read; `Rooms.update_room` checks it again inside its
  transaction and fails, rolling back, when it no longer holds. The form sends plain text, stripped of the space around
  it, which the web layer turns into HTML (`HtmlSanitizer.from_text`) for `Rooms.post`, unless the form has
  `message[format]=html` (the editor to come): its body is HTML and goes to `Rooms.post` as it is; every body that `Rooms`
  gives out is cleaned as it is read (`Rooms.clean`, called by `Rooms.message_of` for the search and by
  `MessageCache` for a page of a room, which hands `Rooms.page`'s `Stored` messages), since a row that Rails wrote
  was never cleaned by this app; the cleaner leaves clean markup as it is, so what `Rooms.post` stored passes
  unchanged, and the view writes the body with its links made (`Autolink.link`, only when it is shown: never stored, and
  not in the JSON of the bots API).
  Deleting a room is for its maker and an account administrator, of any kind (`Rooms.administrable?`; another member is
  answered 403, after the membership check): `Rooms.destroy_later` closes an open room and deletes its memberships in one
  transaction (it checks the right again inside), then `RoomDeletion` (a task that the request starts, one connection of
  the pool per message) calls `Rooms.delete_next_message` until none is left and then `Rooms.delete_room`, trying a
  step again when the database is busy (`RoomDeletion.retry`) and logging, not sweeping, what a failure leaves. Never
  delete the messages of a room in one transaction: it holds the write lock until the last.
  Editing and deleting a message is for its author and an account administrator (`Rooms.changeable?`; anybody else in the
  room is answered 403, after the 404 of a room or a message that is not found): `Rooms.update_message` and
  `Rooms.delete_message` check the right again inside their transaction, and an edit rewrites the three rows of a message
  as `post` wrote them. The Edit link is the one thing in `Views.message` that depends on the viewer (`controls`), so
  `MessageCache.list` takes the person and the key holds the flag; the markup without it is the benchmark's, unchanged.
- Last room: `GET /` opens `Rooms.last_visited`: the room of the `last_room` cookie when the person has a membership in
  it, else the oldest of their rooms, else the welcome page. `RoomsWeb.respond_visit` sets the cookie on a served room page
  only (never from a handler that answers a 404), after the page cache, so a cached page sets it too. Specs that need the
  sidebar get `/users/me/sidebar`, not `/`.
- Boosts: a person reaches a message only through a `memberships` row of its room (`Boosts.reach`), so a message of a room
  they are not in and a message that does not exist are the same 404, before the form is read. Only the booster removes a
  boost: anybody else, an administrator included, gets the 404 (`Boosts.remove` checks the booster, the membership and
  the status again inside its transaction). A text is 1 to `Boosts.MAX_CONTENT_LENGTH` (16) characters once stripped, on
  every path. Adding or removing touches the message and the room (`touch: true`), so `refresh`, the message cache and the
  page cache see it. `Rooms` reads the boosts of a message in the same query (`Boosts.COLUMN`, a JSON column), so every
  `Stored` and `Message` has `boosts`, and `MessageCache.key` holds them. The markup of a boost is the same for every
  viewer (the live stream renders it once): the form that removes it is shown by `--boost-remove`, which `viewer_style`
  sets on the boosts of the person who looks. The broadcast (`CableWeb.boost_added`, `boost_removed`) is sent after the
  connection is back in the pool, as for messages.
- Message cache: the markup of each message of a room page and of the older messages (`Views.message`) is cached by
  `MessageCache` in one process-wide `std/cache` store (`CAMPFIRE_CACHE_MB`, 64 by default, 0 for none), under a key of
  the id, `updated_at` and a SHA-256 of everything else the markup shows (author, time, body), as Rails' partial
  does. Whatever `Views.message` starts to show must go in `MessageCache.key`. The pages must be the same bytes with the
  cache on and off (`specs/message_cache.feature`).
- Page cache: the room page, the page of older messages, the sidebar and the search are kept whole by `PageCache`
  (`CAMPFIRE_RESPONSE_CACHE_MB`, 64 by default, 0 for none; Rails' name and default), as Rails' `CachedResponses`
  does. The key of the room page and the sidebar holds the version of the database (`Database.version`: `PRAGMA
  data_version` of a read-only connection of its own, the observer, read inline by `repo/version_reader.agc`), the
  kind of page, the person (id, and a digest of name and role, which the sign-in filter looked up after the version), the room and
  `before` (the sidebar has no room), so any commit by anybody means a new key and nothing has to be dropped by hand
  (the pages that are kept in a place of the person, below, hold the version in their stamp instead); the version is
  read before the page is made, so a kept page is never older than its key. Only a 200 is kept (a 404 looks the
  membership up each time), a room page with `?before=` is not kept (one person could fill the cache with a page for
  every number), and a hit skips the room lookup because a change of members is a commit. If the observer fails, the
  page is made and not kept. The words of a search are the client's to choose without a bound, so the search relaxes "a
  key per version": a person has `search_slots` places for search pages (`CAMPFIRE_SEARCH_PAGES`, 8 by default), chosen
  by the words, each kept with the version, the person's state and the words (a page of another stamp is a miss and is
  written over), so a person holds at most that many search pages whatever they type, and words longer than
  `Searches.MAX_QUERY_LENGTH` are not kept. The people of the sessions live in a store of their own
  (`CAMPFIRE_SESSION_CACHE_MB`, 4 by default), so that the churn of pages cannot push a session out. The `?before=` and
  `?after=` pages of older messages are keyed by a number the client chooses too, so they relax "a key per version" the
  same way: a person has `cursor_slots` places for each of the kinds `MESSAGES` and `AFTER` (`CAMPFIRE_CURSOR_PAGES`,
  16 by default), chosen by the hash of the room and the cursor, each kept with the version, the person's state, the
  room and the cursor, so a person holds at most that many pages of each kind and a flood of cursors writes over the
  pages of the one who sends it (two cursors of one place take turns). A page can be far above its typical 16 KB (40
  long messages), so the store as a whole (`CAMPFIRE_RESPONSE_CACHE_MB`) is the bound on bytes, and the places bound
  the number of pages of one person.
  The sign-in filter reads the version first for a `GET` or `HEAD` of a page that is kept (`PageCache.cached?`,
  `PageCache.watch`, kept for the handler with `PageCache.seen`) and looks the person up after it: the person of a
  session is kept under the version too (`known_user`, `remember_user`), so a hit costs one inline read of the observer and
  none of the pool; it is valid for that version and until the session ends (`Auth.Session`), and a sign-out, a
  deactivation, a ban or a rename is a commit and so a miss. A hit does not touch
  the session (`Auth.user_for`), so `last_active_at` can be older than its five-minute refresh on a quiet database;
  only Rails reads it. Never keep a person under a key that has no version. A page that starts to depend on something
  that no commit changes (the time, a request header, a file) must not use this cache or must put that in the key.
  Pages carry a weak `ETag` and answer `If-None-Match` with a 304; the `client_message_id` of the form is drawn when
  the page is made, so nothing may drop a message because its id was seen. The `I run the sql` steps write on another
  connection, so a spec that changes the database between two gets checks the invalidation:
  `specs/page_cache.feature`.
- Live (`/cable`, `docs/cable.md`): the room page and `GET /users/me/sidebar` name their streams with
  `<turbo-cable-stream-source channel="X" signed-stream-name="Y">`, that exact markup (the benchmark scrapes it).
  `/cable` is in `PUBLIC_PATHS` (a 302 on the handshake makes the Rails client retry in a loop) and `CableWeb.connect`
  looks the session up itself. A handler of a channel runs on the loop of its connection, so it does a database call
  and nothing that waits. Authorization is done when a subscription is made (`RoomMessagesChannel` checks the
  membership of the room in the verified stream name, and `Turbo::StreamsChannel` refuses those names). The session
  of a connecting socket and the membership of a subscription are kept under the version of the database, like the
  person of a page (`CableWeb.standing`, `session_person`), so any commit is a miss; keep it that way, and a check that
  fails refuses that subscription only, never `Channels.disconnect` (that is for a right that was taken away). A route
  broadcasts after its database connection is back in the pool (`announced` in `web/rooms.agc`), and the fan-out of a
  notice to each member runs in a task of its own, and only while the hub has a connection
  (`CableWeb.message_created`). Who is connected lives in memory (`Presence`), never in
  `memberships.connected_at`. `CAMPFIRE_MAX_CONNECTIONS` must stay above the clients and the posters.
- HTML bodies: markup that did not come from a view is shown only after `HtmlSanitizer.sanitize` (it writes tags
  from its own allowlist and nothing else of the input but text and the checked `href` of a link), and then
  with `<%== %>`, as element content only: `'` and `"` are not escaped, so the output never goes inside an
  attribute or a script. A body is checked against `Config.max_message_length` (`CAMPFIRE_MAX_MESSAGE_LENGTH`,
  `Rooms.body_problem`) before `post` or `update_message`, so the work of the sanitizer is bounded by it (a form's text grows a few times
  in `from_text` first). Its most, 80000, is what fits the 1 MiB body of the server. A change to its lists adds a case
  to `test/html_sanitizer_test.agc`, an XSS one for a new tag or attribute.
- Message windows: `Rooms.page` (before), `Rooms.page_after`, `Rooms.around` and `Rooms.since` read by `created_at` then
  `id`, never by id alone. `/rooms/:id/:segment` serves `@MESSAGE` because Bond params are whole segments (the handler
  404s any other segment); it is not kept in `PageCache` (a cursor per message), `?after=` is (kind `AFTER`).
  `refresh` compares `created_at`/`updated_at` as text against `INSTANT` of `rooms.agc` (the millisecond time written as the
  columns are), answers Turbo Stream whatever `Accept` says, reads `since` as `to_i` (its leading digits) and compares with `>=`, so a message in the
  same millisecond as the last one the client saw is not skipped.
- Account settings: `/account/edit`, `PATCH /account` (name) and `PATCH`/`DELETE /account/users/:id` (role, removal =
  `Accounts.deactivate`) are administrator-only writes: 403 for a member before the form is read, then 404 for a user
  who is not an active person, then 400/422 for the form. `Accounts.set_role` and `Accounts.rename` check that the actor
  is an active administrator again inside the transaction, and `set_role` refuses the actor's own row, so the account always
  keeps an administrator. `AuthWeb.form_method` reads `_method` for every `POST` override.
- Bots: `/account/bots` and its paths are administrator-only writes and pages (403 for a member before the bot or the
  form is read, then 404 for a bot that is not an active one, then 400/422). `Bots.*` check the actor again inside their
  transaction. A key is `ID-TOKEN` with a 12-character `[A-Za-z0-9]` token (`Bots.new_token`, bytes from 248 on skipped
  so each character is as likely), and only an active bot has a key that names it; a new token or a deactivation ends
  the old key. The pages hold keys, so they are `no-store`. The webhook URL and the avatar of Rails' form wait for #78
  and #73.
- Bot messages API (`/rooms/ID/KEY/messages`, `docs/people.md`): the key in the path is the whole login. `Bots.authenticate`
  finds the bot by id with the rule of the admin pages (active, role bot) and compares the whole key with
  `OpenSSL.HMAC.secure_compare`; a session is never read on these paths. `AuthWeb.bot_api?` (the non-empty segments, as the router
  reads them) lets them past the sign-in filter and takes `Origin` and `Sec-Fetch-Site` off the request before
  `Bond.csrf`, so no browser path may match it: a segment `messages` where the key goes is not the API. The bot is 404
  for a key, a room it is not in and a message not in the room, 403 for a message of somebody else; a bot never changes
  more than its own. Params of one place in a Bond route share a name, so the segment after a room is `:segment` for
  `ROOM_AT` and the key alike. The API broadcasts through `CableWeb` after its connection is back in the pool, as
  `RoomsWeb` does.
- Who may create rooms: `Accounts.room_creation_restricted?` reads the key `restrict_room_creation_to_administrators`
  of `accounts.settings` with `json_extract`, guarded by `json_valid`. `RoomsWeb.may_create_rooms?` is the one check,
  used by the four open and closed create routes (403 before the form is read) and by `sidebar_of` (the links). A
  direct room is never restricted, as in Rails. `Accounts.save` writes the name and the flag in one transaction with
  `json_set`, keeping the other keys.
- Involvement: `/rooms/ID/involvement` reads and sets the person's own `memberships.involvement` (`Rooms.involvement`,
  `Rooms.set_involvement`); the choices a room offers are `Rooms.involvement_levels` (`mentions` shown, `invisible`
  hidden; a direct room offers none, as Rails never lets it be `invisible`), and anything else is 422 with nothing
  written. Saving `mentions` keeps an `everything` or `nothing` row as it is; #57 and #81 bring those levels back.
  Membership is checked first (404), then the form. `invisible` is the only way out of a sidebar (the room stays
  reachable and the person a member), and `visible` and `receive` already skip it.
- Bans: `Bans.ban`/`Bans.unban` (administrator only, never oneself, an active or banned person only) run in one
  transaction that checks the actor again. A ban writes one `bans` row for each distinct public session address
  (`Bans.public_address?`), ends the sessions and sets `status` banned; `ContentRemoval` then deletes the messages one by
  one and tells the rooms, and `Hangup.user` closes the sockets. `AuthWeb.reject_banned` is a `before` filter after
  `Bond.csrf`: a request that is not `GET` or `HEAD` from a banned address halts with 429 (`Bond.halt`: a plain
  `Bond.text` does not stop the chain).
- Search: a query is words, never FTS5 syntax. `Searches.words` turns everything that is not a letter, digit or `_` into
  a separator (as `SearchesController#query` does) and `Searches.match` puts each word in double quotes, so a query
  cannot make the index fail; never hand the text of a client to `MATCH` in any other way. A search reads the rooms the
  person has a `memberships` row for, any involvement, newest 100, shown oldest first, with `Rooms.MESSAGE_SELECT`.
  Only `POST /searches` writes `searches`, as Rails does, and `DELETE /searches/clear` (or a `POST` with `_method=delete`) deletes
  the signed-in person's rows with one `where user_id = ?` and nothing else: the route names no other person. The page
  links back to `Rooms.last_visited` (the `last_room` cookie), which is a header that no commit changes, so
  `PageCache.search_spot` puts the cookie in the stamp.
- Avatars: `/users/TOKEN/avatar` takes a Rails `signed_id` (purpose `user/avatar`) checked by `SignedId.verify` with the
  key of `SECRET_KEY_BASE`, and answers the WebP file of the variant that Rails stored (`Avatars.find`, `Avatars.path`:
  a key that is not 4 to 64 of `[0-9a-z]` is never made a path), else initials. The app makes no image. The router wants
  one name for the segment under `/users/`, so the token is `:id`. The links of the profile and the user page end in
  `?v=` and the digits of the user's `updated_at` (`Avatars.version`), so a change of the picture is a new link.
  `DELETE /users/me/avatar` (`Avatars.remove`, own only, 404 for another's) deletes the rows in one transaction and the
  files after it commits. The Active Storage rows and files of the specs are made by Rails
  (`specs/fixtures/rails/make_avatar.sh`).
- Assets: never edit `public/assets/` or `src/campfire_web/asset_names.agc`. Change `app/assets/stylesheets/` or
  `app/javascript/` and run `make assets` (`npm ci` first; Node 20 or later, `.nvmrc` says 22, `.npmrc` runs no install scripts; esbuild and sass are pinned in `package.json`
  and `package-lock.json`, `node_modules/` is not committed). It writes `campfire-DIGEST.css` and `campfire-DIGEST.js`
  (DIGEST the first 16 hex digits of the SHA-256 of the file) and the names that `Routes.STYLESHEET` and `Routes.SCRIPT` read.
  The built files are committed, so `agentica test`, the benchmark and the Docker image need no Node; CI runs
  `make assets-check` (the same test) and fails if the build changes a committed file (`specs/assets.feature` checks the names). The SCSS layout
  rule (grid first, flex only for one-dimensional bits) is at the top of `application.scss`. `/assets/` is public
  (`AuthWeb.public?`). The script is progressive enhancement: the room page, the edit page and every page with the sidebar link it, every form works
  without it, and it stays about 18 KB minified with no framework (`DESIGN.md`, "Script", which also has its keys;
  `tools/keys_check.js` checks them in a browser, by hand). The composer textarea has no `autofocus` (a phone would
  open its keyboard on each load).
- The Dockerfile writes `gzip -9 -k -n` copies of the CSS and the JS of `public/assets/` next to them, which Bond sends to a client that
  takes gzip.
- A UI change follows `DESIGN.md` and updates it with the stylesheet. Markup that specs match byte for byte (links, headings,
  forms, the message `<div>`) takes no class: style it by element.
- Campfire's CSS, JS and images are MIT (37signals): keep their notice when a file is copied (see README).
- Code comments say why. Follow `agentica-programming` and `agentica-code-guidelines` for the style.

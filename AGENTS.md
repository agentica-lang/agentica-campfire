# agentica-campfire

A port of ONCE Campfire (group chat) in Agentica, on Bond. `docs/plan.md` has the plan and the phases;
`README.md` has the status.

## Map

```text
campfire.agc    the program (`make run`): config from the environment, the data folder, then the app
src/campfire/   the domain: it knows nothing about HTTP or Bond
                config.agc (host, port, data folder, database url, session secret), data_dir.agc (the
                private data folder), slots.agc (a limit on concurrent hashes), passwords.agc (scrypt),
                accounts.agc (the join code and the people: deactivate and reactivate, over SQL), auth.agc
                (first run, the join link, sign in, sign out and password reset, over SQL), rooms.agc (open,
                closed and direct rooms, memberships and messages over SQL)
src/campfire/repo/   database.agc (open and migrate; `with_connection` for a request), migrations.agc
                (the schema, one numbered migration per table), rows.agc (reading a column of a row)
src/campfire/mail/   mailer.agc (the task that sends email off the request path), smtp.agc and
                smtp_message.agc (sending email: the client and the message builder; they import no other
                app module, so they can move to their own package)
src/campfire_web/    HTTP, on Bond: app.agc (start: database, then server), web.agc (the routes), routes.agc
                (the paths), views.agc (EAG templates, the reset email too), auth.agc (cookie sessions,
                CSRF, the sign-in filter, the routes of first run, the join link, sign in, sign out and
                password reset), accounts.agc (the people page and those posts), rooms.agc (the routes
                and forms of rooms)
specs/          BDD: *.feature, steps.agc (the app and the database), http_steps.agc (a browser with
                cookies), smtp_steps.agc (an SMTP client against a peer), mail_steps.agc (the peer as the
                mail server of the app: reads its email, follows the link), fixtures/server.agc (the app, from
                the environment that the steps set), fixtures/smtp_peer.agc (a hermetic SMTP server that writes
                down the dialogue; its test CA and certificate are in fixtures/tls, made by make-certs.sh)
test/           unit tests (*_test.agc)
agentica.toml   the manifest; Bond and agentica-db are pinned by commit, agentica.lock has their hashes
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
- Schema changes are new migrations in `src/campfire/repo/migrations.agc`, numbered after the last one. Never edit one that has
  shipped (`Migrate` refuses it on a database that ran it); `specs/schema.feature` pins the checksum of each one,
  so a PR that edits shipped SQL fails there. A table that the specs name in `specs/database.feature` is added there
  too.
- Never write `insert or replace into messages` (it skips the delete trigger and corrupts the search index; an
  upsert with `on conflict do update` is fine). Page a room by `id`, not by `created_at`.
- Auth: a page is public only if `PUBLIC_PATHS` in `src/campfire_web/auth.agc` names it (the sign-in filter is
  deny-by-default); the one exception is `/join/CODE` (`AuthWeb.public?`: exactly `/join/` and one segment), since its
  code is part of the path and cannot be a fixed entry, and the handler answers a wrong code with the 404 of any missing
  page (`Routes.MISSING`, the one 404 text of every handler and of the app for a path with no route). A request opens
  its own database connection (`Database.with_connection`), since Bond runs a request in its own task (a handler
  opens one and does all its work on it, the person included: `AuthWeb.current_user_in`; the sign-in filter still
  opens another, since a Bond `Conn` cannot carry the person on); a `sqlite::memory:` database is therefore not usable by the app. Never log or store a plain
  password; a form that is shown again never holds the password.
- Invitation: `Auth.join` makes a member for `/join/CODE` (the form's own path) and calls `Rooms.grant_open_rooms` in
  the transaction that makes the user; the code, the form and the email are checked before a hashing slot is taken (a form
  that cannot work takes no slot), and the code and the email again inside the transaction, so a regenerated code refuses
  a form that was open and two forms with one email make one person. Joining never reactivates a deactivated person
  (their email counts as taken). Everything of `Accounts` that changes something (`deactivate`, `reactivate`,
  `regenerate_join_code`) checks inside its transaction that the actor is an active administrator, and an
  administrator cannot deactivate themselves; deactivating deletes the person's sessions and reset links, and
  reactivating calls `Rooms.grant_open_rooms`. A session is opened with one insert that reads `active` itself
  (`open_session`), so a sign-in that races a deactivation leaves no row for a reactivation to revive. The pages with
  the join code are `no-store` and `no-referrer`. Sign-up is the deliberate exception to "a page that asks for an email
  answers the same for every address": it answers 422 for an email that has an account, since a person who is joining
  needs to know to sign in instead, and only whoever holds the link can ask; regenerating the link ends that.
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
  exists). Whatever makes a user after the open rooms exist (the invitation), and whatever reactivates one (`active`
  0 to 1, who has missed the rooms made meanwhile), calls `Rooms.grant_open_rooms`; whatever makes an open room puts
  every active person in it (`Rooms.create_open`); a closed room has only the chosen active people and its maker
  (`Rooms.create_closed`), and a direct room is found by its exact set of people before one is made
  (`Rooms.open_direct`), in one transaction (the people are checked as active inside it, so the search counts who
  is inserted). The settings form carries `was`, the people in the room when it was drawn, and an update applies only
  its diff (the chosen that are not in `was` are added, `was` minus the chosen is taken out), so a stale form neither
  takes out someone added since nor brings back someone taken out; the sender is never offered. The settings of a room
  exist for a closed room only, and for any other room the person is in they are the same 404. Only the maker and an
  account administrator may change a closed room (`Rooms.editable?`): another member is answered 403, after the
  membership check (a non-member is 404) and before the form is read; `Rooms.update_closed` checks it again inside its
  transaction and fails, rolling back, when it no longer holds. A message is plain text: stripped of the space around
  it, stored so, and escaped by the view; keep it plain text until the rich text phase. `client_message_id` is the
  dedupe key with the creator, so it must be unique per person, not per room: a reuse in another room is dropped
  without a word.
- No Dockerfile or assets yet: each is a later PR of `docs/plan.md` phase 2.
- Campfire's CSS, JS and images are MIT (37signals): keep their notice when a file is copied (see README).
- Code comments say why. Follow `agentica-programming` and `agentica-code-guidelines` for the style.

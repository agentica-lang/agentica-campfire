# agentica-campfire

A port of ONCE Campfire (group chat) in Agentica, on Bond. `docs/plan.md` has the plan and the phases;
`README.md` has the status.

## Map

```text
campfire.agc    the program (`make run`): config from the environment, the data folder, then the app
src/            config.agc (host, port, data folder, database url), data_dir.agc (the private data
                folder), app.agc (start: database, then server), database.agc (open and migrate),
                migrations.agc (the schema, one numbered migration per table), web.agc (routes),
                views.agc (EAG templates)
specs/          BDD: *.feature, steps.agc, fixtures/server.agc (the app on a free port and a given database)
test/           unit tests (*_test.agc)
agentica.toml   the manifest; Bond and agentica-db are pinned by commit, agentica.lock has their hashes
```

## Commands

- `make install` fetches `deps/` from the lock (git ignores `deps/`). `make check`, `make fmt-check`, `make test`, `make run`.
- Agentica 0.22.0 or later. CI pins it with its sha256 (`AGENTICA_VERSION`, `AGENTICA_SHA256` in
  `.github/workflows/ci.yml`).
- To move Bond or agentica-db: `agentica add bond https://github.com/agentica-lang/bond --ref COMMIT` (or `db`
  and `https://github.com/agentica-lang/agentica-db`), commit the lock.

## Rules

- BDD first: a behavior is a Gherkin scenario in `specs/` before the code. A test over HTTP uses 127.0.0.1 and port 0.
  Unit tests (`test/`) only for pure helpers.
- Views are EAG templates with `<%@ escape &Bond.escape %>` as the first line, so every `<%= %>` is escaped.
  `<%== %>` only for markup that the program wrote, never for a value of a client.
- `agentica.toml` has `blank_line_after_end = true`: every bare `end` is followed by an empty line.
- Schema changes are new migrations in `src/migrations.agc`, numbered after the last one. Never edit one that has
  shipped (`Migrate` refuses it on a database that ran it); `specs/schema.feature` pins the checksum of each one,
  so a PR that edits shipped SQL fails there. A table that the specs name in `specs/database.feature` is added there
  too.
- Never write `insert or replace into messages` (it skips the delete trigger and corrupts the search index; an
  upsert with `on conflict do update` is fine). Page a room by `id`, not by `created_at`.
- No Dockerfile, assets or auth yet: each is a later PR of `docs/plan.md` phase 2.
- Campfire's CSS, JS and images are MIT (37signals): keep their notice when a file is copied (see README).
- Code comments say why. Follow `agentica-programming` and `agentica-code-guidelines` for the style.

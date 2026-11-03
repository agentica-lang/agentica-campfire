# agentica-campfire

Group chat written in [Agentica](https://github.com/agentica-lang/agentica): a port of 37signals' [ONCE Campfire](https://github.com/basecamp/once-campfire), built on [Bond](https://github.com/agentica-lang/bond), EAG templates and [agentica-db](https://github.com/agentica-lang/agentica-db).

This is an independent project. It is not affiliated with or endorsed by 37signals. Campfire is MIT licensed (copyright 37signals, LLC). Any CSS, JavaScript or images reused from it keep that copyright and license notice, and the notice is added to this repository when the first file is copied.

Status: a skeleton with a database. A Bond server with a home page (an EAG template that escapes what it inserts) and a health route, on a SQLite database whose schema (accounts, users, sessions, rooms, memberships, messages, boosts, attachments, webhooks and the message search index) is created by numbered migrations at start-up. See [docs/plan.md](docs/plan.md) for what Agentica, Bond and agentica-db still need, the MVP and the phases.

## Run

Needs [Agentica](https://github.com/agentica-lang/agentica) 0.22.0 or later on `PATH`.

```sh
make install   # fetch Bond and agentica-db (pinned by commit in agentica.toml) into deps/
make run       # http://127.0.0.1:3000/
```

`CAMPFIRE_HOST` and `CAMPFIRE_PORT` change where it listens (`CAMPFIRE_PORT=0` picks a free port, and the last line of output says which). `GET /health` answers `{"schema_version":10,"status":"ok"}`.

The app keeps its files in `CAMPFIRE_DATA_DIR` (`data/` by default, no `?` in it). Start-up makes the folder and the parents that are missing with mode 0700 (the database holds password digests and tokens, and SQLite makes the file with the umask), and leaves a folder that exists as it is. The database is `sqlite:DATA_DIR/campfire.db?fts5=required` unless `CAMPFIRE_DATABASE_URL` says another [agentica-db SQLite url](https://agentica-lang.github.io/agentica-db/guide/sqlite/) (WAL mode and foreign keys are on by default; add `fts5=required` to stop at start-up when the system SQLite has no FTS5, which message search needs). At start-up the app runs the migrations that the database has not seen (`src/migrations.agc`) and prints `database: schema version N, migrations applied: M`; if the database cannot be opened or migrated it exits with code 1 and a message that names the variable. Run one instance at a time per database: migrations run from one process, and two started together make one of them fail on `schema_migrations`. A url with `foreign_keys=off` is refused at start-up, since the schema relies on cascades. Back up with `VACUUM INTO`, or copy the file after the app stops: while it runs, recent writes may live in the `-wal` file.

## Develop

The tests are BDD first: `specs/home.feature` and `specs/database.feature` start the app on 127.0.0.1 and a free port, with a fresh database, and talk to it over HTTP; `specs/schema.feature` checks the rules of the schema (foreign keys, unique values, the search index) through SQL steps; `test/` has unit tests of the config and the layout.

```sh
make check
make test
```

CI (`.github/workflows/ci.yml`) pins the Agentica release with its sha256.

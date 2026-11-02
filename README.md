# agentica-campfire

Group chat written in [Agentica](https://github.com/agentica-lang/agentica): a port of 37signals' [ONCE Campfire](https://github.com/basecamp/once-campfire), built on [Bond](https://github.com/agentica-lang/bond), EAG templates and [agentica-db](https://github.com/agentica-lang/agentica-db).

This is an independent project. It is not affiliated with or endorsed by 37signals. Campfire is MIT licensed (copyright 37signals, LLC). Any CSS, JavaScript or images reused from it keep that copyright and license notice, and the notice is added to this repository when the first file is copied.

Status: a skeleton. A Bond server with a home page (an EAG template that escapes what it inserts) and a health route. See [docs/plan.md](docs/plan.md) for what Agentica, Bond and agentica-db still need, the MVP and the phases.

## Run

Needs [Agentica](https://github.com/agentica-lang/agentica) 0.22.0 or later on `PATH`.

```sh
make install   # fetch Bond (pinned by commit in agentica.toml) into deps/
make run       # http://127.0.0.1:3000/
```

`CAMPFIRE_HOST` and `CAMPFIRE_PORT` change where it listens (`CAMPFIRE_PORT=0` picks a free port, and the first line of output says which). `GET /health` answers `{"status":"ok"}`.

## Develop

The tests are BDD first: `specs/home.feature` starts the app on 127.0.0.1 and a free port and talks to it over HTTP; `test/` has unit tests of the config and the layout.

```sh
make check
make test
```

CI (`.github/workflows/ci.yml`) pins the Agentica release with its sha256.

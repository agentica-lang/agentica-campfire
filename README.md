# agentica-campfire

Group chat written in [Agentica](https://github.com/agentica-lang/agentica): a port of 37signals' [ONCE Campfire](https://github.com/basecamp/once-campfire), built on [Bond](https://github.com/agentica-lang/bond), EAG templates and [agentica-db](https://github.com/agentica-lang/agentica-db).

Status: a skeleton with sign-in, the join link, the people page, password reset by email, and rooms with messages, on SQLite. The database is the schema of a Rails Campfire, so that a database that Rails made opens as it is: the people, the account, the rooms, the messages (HTML bodies and the search index) and the tables for boosts, webhooks, bans, searches, push and Active Storage are there; the routes that use some of them are next. See [docs/plan.md](docs/plan.md) for what is missing and the phases.

This project is licensed under Apache-2.0 (see [LICENSE](LICENSE)). It is independent. It is not affiliated with or endorsed by 37signals. Campfire is MIT licensed (copyright 37signals, LLC). Any CSS, JavaScript or images reused from it keep that copyright and license notice, and the notice is added to this repository when the first file is copied (`specs/fixtures/rails/LICENSE.37signals`, for the Rails schema that the specs compare with).

## Run

Needs [Agentica](https://github.com/agentica-lang/agentica) 0.24.1 or later on `PATH` to run the app and its tests.

```sh
make install   # fetch Bond and agentica-db (pinned by commit in agentica.toml) into deps/
CAMPFIRE_SESSION_SECRET=$(openssl rand -hex 32) make run   # http://127.0.0.1:3000/
```

`CAMPFIRE_SESSION_SECRET` is required (at least 32 bytes) and has no default. Behind HTTPS also set `CAMPFIRE_SECURE_COOKIES=true`.

On the first run there is no account, so every page shows a setup form (a name, an email and a password of at least 8 characters). Finishing it makes the first user, an administrator, and signs you in. Whoever reaches `/first_run` first gets that role: do the setup before anyone else can reach the app. It listens on `127.0.0.1` by default; keep `CAMPFIRE_HOST` that way until the account exists.

## Docker

```sh
docker build -t once-campfire-agentica:app .
docker run --rm --init -p 3000:3000 -e CAMPFIRE_HOST=0.0.0.0 -e CAMPFIRE_PORT=3000 \
  -e SECRET_KEY_BASE=$(openssl rand -hex 64) -v "$PWD/storage:/rails/storage" once-campfire-agentica:app
```

Or with Compose, which keeps the data in the `campfire-storage` volume and publishes the port on `127.0.0.1` only:

```sh
echo "SECRET_KEY_BASE=$(openssl rand -hex 64)" > .env
docker compose up -d --build
```

Local settings, such as a network, an address or `CAMPFIRE_BASE_URL`, go in `docker-compose.override.yml`. Compose reads that file on its own; keep it and `.env` out of git.

The image has the pinned Agentica release, the app and its packages (no network at run time) on Debian 13 slim. `docker/entrypoint.sh` maps the environment of the [Rails benchmark harness](https://github.com/basecamp/once-campfire-verification) to `CAMPFIRE_*` (the database is `/rails/storage/db/production.sqlite3`, the Active Storage files `/rails/storage/files`; `HTTP_PORT` is the port; the session secret comes from `SECRET_KEY_BASE`); a `CAMPFIRE_*` variable that you set wins. It listens on `127.0.0.1` unless `CAMPFIRE_HOST` says otherwise. The image is x86_64 only. In the benchmark harness, `bin/seed` writes `SECRET_KEY_BASE`.

## Develop

```sh
make check       # type-check
make fmt-check   # formatting
make test        # the features of specs/ and the tests of test/
```

The tests are BDD first and take under a minute. CI (`.github/workflows/ci.yml`) pins the Agentica release with its sha256. Rules for contributors and agents: [AGENTS.md](AGENTS.md).

## Docs

- [docs/configuration.md](docs/configuration.md): every `CAMPFIRE_*` variable, the data folder and the database.
- [docs/security.md](docs/security.md): sessions, passwords, CSRF, public pages, known gaps.
- [docs/rooms.md](docs/rooms.md): open, closed and direct rooms, settings, messages.
- [docs/people.md](docs/people.md): the join link and the people page.
- [docs/mail.md](docs/mail.md): password reset, SMTP and the mailer.
- [docs/plan.md](docs/plan.md): what Agentica, Bond and agentica-db still need, the MVP and the phases.

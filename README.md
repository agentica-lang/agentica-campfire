# agentica-campfire

Group chat written in [Agentica](https://github.com/agentica-lang/agentica): a port of 37signals' [ONCE Campfire](https://github.com/basecamp/once-campfire), built on [Bond](https://github.com/agentica-lang/bond), EAG templates and [agentica-db](https://github.com/agentica-lang/agentica-db). The goal is parity with Rails Campfire.

Status: a skeleton with sign-in, the join link, the people page, password reset by email, and rooms with messages, on SQLite. The database is the schema of a Rails Campfire, so a database that Rails made opens as it is (see [docs/configuration.md](docs/configuration.md#data-folder-and-database)). Some tables are there before the routes that use them. What is missing, and the phases, are in [docs/plan.md](docs/plan.md).

This project is licensed under Apache-2.0 (see [LICENSE](LICENSE)). It is independent. It is not affiliated with or endorsed by 37signals. Campfire is MIT licensed (copyright 37signals, LLC). Any CSS, JavaScript or images reused from it keep that copyright and license notice (`specs/fixtures/rails/LICENSE.37signals`).

## Run

Needs [Agentica](https://github.com/agentica-lang/agentica) 0.25.0 or later on `PATH` to run the app and its tests.

```sh
make install   # fetch Bond and agentica-db (pinned by tag in agentica.toml) into deps/
CAMPFIRE_SESSION_SECRET=$(openssl rand -hex 32) make run   # http://127.0.0.1:3000/
```

`CAMPFIRE_SESSION_SECRET` is required (at least 32 bytes). Behind HTTPS also set `CAMPFIRE_SECURE_COOKIES=true`. All variables are in [docs/configuration.md](docs/configuration.md).

On the first run there is no account, so every page shows a setup form. Finishing it makes the first user, an administrator. Whoever reaches `/first_run` first gets that role, so do the setup before anyone else can reach the app: the app listens on `127.0.0.1` by default. See [docs/security.md](docs/security.md).

## Docker

```sh
[ -f .env ] || echo "SECRET_KEY_BASE=$(openssl rand -hex 64)" > .env
docker compose up -d --build   # http://127.0.0.1:3000/
```

More in [docs/docker.md](docs/docker.md).

## Tests

```sh
make check       # type-check
make fmt-check   # formatting
make test        # the features of specs/ and the tests of test/
```

The tests are BDD first and take under a minute. Rules for contributors and agents: [AGENTS.md](AGENTS.md).

## Benchmark

Requests per second (higher is better), median of 3 rounds with 16 clients, from the
[Rails Campfire benchmark](https://github.com/basecamp/once-campfire-verification) at ec02deb, with the server on
CPUs 4-7 and the client on CPUs 0-3. Go and Agentica are run `20261106-200652-7` (2026-11-06): Campfire c2cdc7d on
Agentica 0.25.0, and [once-campfire-go](https://github.com/basecamp/once-campfire-go) c4ab53d. Rails is the
reference run `20261105-101743-7` on the same machine.

| Route | Rails | Go | Agentica | Agentica / Rails | Agentica / Go |
| --- | ---: | ---: | ---: | ---: | ---: |
| room_show | 834.3 | 7050.1 | 3042.4 | 3.6x | 43% |
| messages_page | 876.9 | 7412.6 | 3087.6 | 3.5x | 42% |
| sidebar | 990.1 | 8312.0 | 1835.3 | 1.9x | 22% |
| search | 970.8 | 8321.5 | 877.0 | 0.90x | 11% |
| post_message | 88.5 | 979.6 | 583.8 | 6.6x | 60% |

Against run `20261106-130459-7` (Campfire c6147de on Agentica master 7ec41cb, before live updates, chat bubbles,
bans and the rest of [#83](https://github.com/agentica-lang/agentica-campfire/issues/83) group 2), sidebar fell from
2279.3 to 1835.3 (-19%), search from 1038.7 to 877.0 (-16%, now below Rails) and post_message from 665.1 to 583.8
(-12%). Next: win back these three, then close the gap to Go on search and sidebar.

To reproduce it, build the image (`docker build -t once-campfire-agentica:app .`), then run `bench/run.sh --setup` and `bench/run.sh --apps go,agentica` (add `rails` for a new Rails run; Go needs a checkout of once-campfire-go next to the harness). Method and details: [docs/benchmarks.md](docs/benchmarks.md).

## Documentation

- [docs/configuration.md](docs/configuration.md): every `CAMPFIRE_*` variable, the data folder and the database.
- [docs/security.md](docs/security.md): sessions, passwords, CSRF, public pages, known gaps.
- [docs/rooms.md](docs/rooms.md): open, closed and direct rooms, settings, messages.
- [docs/cable.md](docs/cable.md): the `/cable` WebSocket (Action Cable): streams, channels and what is broadcast.
- [docs/people.md](docs/people.md): the join link and the people page.
- [docs/mail.md](docs/mail.md): password reset, SMTP and the mailer.
- [docs/docker.md](docs/docker.md): the image, Compose and the benchmark environment.
- [docs/benchmarks.md](docs/benchmarks.md): how the benchmark is run; [bench/README.md](bench/README.md) has the harness steps.
- [DESIGN.md](DESIGN.md): the visual design system (colours, type, components, accessibility).
- [docs/plan.md](docs/plan.md): what Agentica, Bond and agentica-db still need, the MVP and the phases.

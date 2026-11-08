# agentica-campfire

Group chat written in [Agentica](https://github.com/agentica-lang/agentica): a port of 37signals' [ONCE Campfire](https://github.com/basecamp/once-campfire), built on [Bond](https://github.com/agentica-lang/bond), EAG templates and [agentica-db](https://github.com/agentica-lang/agentica-db). The goal is parity with Rails Campfire.

Status: a skeleton with sign-in, the join link, the people page, password reset by email, and rooms with messages, on SQLite. The database is the schema of a Rails Campfire, so a database that Rails made opens as it is (see [docs/configuration.md](docs/configuration.md#data-folder-and-database)). Some tables are there before the routes that use them. What is missing, and the phases, are in [docs/plan.md](docs/plan.md).

This project is licensed under Apache-2.0 (see [LICENSE](LICENSE)). It is independent. It is not affiliated with or endorsed by 37signals. Campfire is MIT licensed (copyright 37signals, LLC). Any CSS, JavaScript or images reused from it keep that copyright and license notice (`specs/fixtures/rails/LICENSE.37signals`).

## Run

Needs [Agentica](https://github.com/agentica-lang/agentica) 0.27.0 or later on `PATH` to run the app and its tests, and a C compiler (agentica-db builds its native SQLite driver on the first run).

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
CPUs 4-7 and the client on CPUs 0-3. Go and Agentica are run `20261108-222622-7` (2026-11-08): Campfire 8a7616e on
Agentica 0.27.0 with agentica-db 0.8.0 and Bond 0.10.1 (image `sha256:a7e426e7`), and
[once-campfire-go](https://github.com/basecamp/once-campfire-go) c4ab53d. Rails is the reference run
`20261105-101743-7` on the same machine.

| Route | Rails | Go | Agentica | Agentica / Rails | Agentica / Go |
| --- | ---: | ---: | ---: | ---: | ---: |
| room_show | 834.3 | 7077.0 | 9500.9 | 11.4x | 134% |
| messages_page | 876.9 | 7424.0 | 9536.0 | 10.9x | 128% |
| sidebar | 990.1 | 8201.1 | 9357.9 | 9.5x | 114% |
| search | 970.8 | 8360.0 | 8953.4 | 9.2x | 107% |

post_message is left out of this run (`--routes`): on this machine, writes under load stalled for seconds (Go fell from
1135 to 91-211 requests per second, with a p99 up to 3.8 s; Agentica answered some 503s), so the number did not measure
the apps. The other routes of the run: avatar 7646.4 against Go's 21185.9 (36%), static_css 18006.9 against 24902.3
(72%), up 21693.1 against 15314.7 (142%).

Against run `20261108-212335-7` (Campfire e3ce2b9 with Bond 0.10.0, the same day), the avatar answer cache of
[#143](https://github.com/agentica-lang/agentica-campfire/pull/143) and the header work of Bond 0.10.1 changed avatar
from 4170.4 to 7646.4 (+83%) and static_css from 14323.0 to 18006.9 (+26%; against Go, from 61% to 72%); Agentica's four
pages moved by 1-3%. Against run `20261107-171526-7` (Campfire e8ae07b on Agentica 0.26.1 and agentica-db 0.6.0),
room_show went from 4282.9 to 9500.9, messages_page from 6576.8 to 9536.0, sidebar from 8527.6 to 9357.9 and search from
6898.3 to 8953.4; the app changed too between e8ae07b and 8a7616e, so the gain is not Agentica 0.27.0 alone. Earlier
steps are in the history of this file.

To reproduce it, build the image (`docker build -t once-campfire-agentica:app .`), then run `bench/run.sh --setup` and `bench/run.sh --apps go,agentica` (add `rails` for a new Rails run; Go needs a checkout of once-campfire-go next to the harness). Method and details: [docs/benchmarks.md](docs/benchmarks.md).

## Documentation

- [docs/configuration.md](docs/configuration.md): every `CAMPFIRE_*` variable, the data folder and the database.
- [docs/security.md](docs/security.md): sessions, passwords, CSRF, public pages, known gaps.
- [docs/rooms.md](docs/rooms.md): open, closed and direct rooms, settings, messages.
- [docs/cable.md](docs/cable.md): the `/cable` WebSocket (Action Cable): streams, channels and what is broadcast.
- [docs/people.md](docs/people.md): the join link, the people page and the chat bots.
- [docs/mail.md](docs/mail.md): password reset, SMTP and the mailer.
- [docs/docker.md](docs/docker.md): the image, Compose and the benchmark environment.
- [docs/benchmarks.md](docs/benchmarks.md): how the benchmark is run; [bench/README.md](bench/README.md) has the harness steps.
- [DESIGN.md](DESIGN.md): the visual design system (colours, type, components, accessibility).
- [docs/plan.md](docs/plan.md): what Agentica, Bond and agentica-db still need, the MVP and the phases.

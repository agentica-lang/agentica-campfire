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
CPUs 4-7 and the client on CPUs 0-3. Go and Agentica are run `20261106-223859-7` (2026-11-06): Campfire 53e4cc3 on
Agentica 0.25.0, and [once-campfire-go](https://github.com/basecamp/once-campfire-go) c4ab53d. Rails is the
reference run `20261105-101743-7` on the same machine.

| Route | Rails | Go | Agentica | Agentica / Rails | Agentica / Go |
| --- | ---: | ---: | ---: | ---: | ---: |
| room_show | 834.3 | 7057.8 | 3434.7 | 4.1x | 49% |
| messages_page | 876.9 | 7130.6 | 3596.9 | 4.1x | 50% |
| sidebar | 990.1 | 8040.5 | 3706.7 | 3.7x | 46% |
| search | 970.8 | 8133.0 | 3617.6 | 3.7x | 44% |
| post_message | 88.5 | 1011.3 | 623.3 | 7.0x | 62% |

Against run `20261106-200652-7` (Campfire c2cdc7d), the page cache of the sidebar and the search
([#110](https://github.com/agentica-lang/agentica-campfire/pull/110)) took sidebar from 1835.3 to 3706.7 (+102%) and
search from 877.0 to 3617.6 (+312%). The benchmark asks one search query, so both numbers measure cache hits. #110
also keeps the signed-in person until the database changes, so a cached page does not look the person up again (the
end of the session is kept with it since [#113](https://github.com/agentica-lang/agentica-campfire/pull/113)).
room_show gained 13% and messages_page 16% in this run; the A/B in #110 measured about +5% and +6%, so part of that is
run-to-run noise. Every read route is now at 44-50% of Go. The cost that is left is probably the thread hops of the
database layer, as measured in [agentica-db#60](https://github.com/agentica-lang/agentica-db/issues/60). Next: native
modules ([agentica#1149](https://github.com/agentica-lang/agentica/issues/1149)), and on them the statement cache and
fewer per-row hops in agentica-db.

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

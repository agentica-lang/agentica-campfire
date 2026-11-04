# agentica-campfire

Group chat written in [Agentica](https://github.com/agentica-lang/agentica): a port of 37signals' [ONCE Campfire](https://github.com/basecamp/once-campfire), built on [Bond](https://github.com/agentica-lang/bond), EAG templates and [agentica-db](https://github.com/agentica-lang/agentica-db).

Status: a skeleton with sign-in, the join link, the people page, password reset by email, and rooms with plain-text messages, on SQLite. The database is moving to the schema of a Rails Campfire, so that a database that Rails made opens as it is: the people and the account are there, the rooms and messages are next. See [docs/plan.md](docs/plan.md) for what is missing and the phases.

This project is licensed under Apache-2.0 (see [LICENSE](LICENSE)). It is independent. It is not affiliated with or endorsed by 37signals. Campfire is MIT licensed (copyright 37signals, LLC). Any CSS, JavaScript or images reused from it keep that copyright and license notice, and the notice is added to this repository when the first file is copied (`specs/fixtures/rails/LICENSE.37signals`, for the Rails schema that the specs compare with).

## Run

Needs [Agentica](https://github.com/agentica-lang/agentica) 0.23.0 or later on `PATH`.

```sh
make install   # fetch Bond and agentica-db (pinned by commit in agentica.toml) into deps/
CAMPFIRE_SESSION_SECRET=$(openssl rand -hex 32) make run   # http://127.0.0.1:3000/
```

`CAMPFIRE_SESSION_SECRET` is required (at least 32 bytes) and has no default. Behind HTTPS also set `CAMPFIRE_SECURE_COOKIES=true`.

On the first run there is no account, so every page shows a setup form (a name, an email and a password of at least 8 characters). Finishing it makes the first user, an administrator, and signs you in. Whoever reaches `/first_run` first gets that role: do the setup before anyone else can reach the app. It listens on `127.0.0.1` by default; keep `CAMPFIRE_HOST` that way until the account exists.

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

# Configuration

The app reads everything from the environment (`src/campfire/config.agc`). A bad value stops
start-up with a message that names the variable.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CAMPFIRE_SESSION_SECRET` | none, required | Signs the session cookie; at least 32 bytes. Keep it out of the repository and the image, and use the same value on every start (a new one signs everybody out). |
| `CAMPFIRE_SECURE_COOKIES` | `false` | `true` behind HTTPS: the cookie is `Secure` with the `__Host-` prefix, so a browser refuses it over plain HTTP. The first line of output says which. |
| `CAMPFIRE_HOST` | `127.0.0.1` | Address to listen on. |
| `CAMPFIRE_PORT` | `3000` | 0 to 65535. `0` picks a free port; the last line of output says which. |
| `CAMPFIRE_DATA_DIR` | `data` | Folder for the files of the app. No `?` in it. |
| `CAMPFIRE_DATABASE_URL` | `sqlite:DATA_DIR/campfire.db?fts5=required` | Another [agentica-db SQLite url](https://agentica-lang.github.io/agentica-db/guide/sqlite/). |
| `CAMPFIRE_BASE_URL` | unset | Public address: a scheme, a host and maybe a port, no path (`https://campfire.example.com`). Required with `CAMPFIRE_SMTP_URL`. The join link starts with it. |
| `CAMPFIRE_SMTP_URL` | unset (no email) | How to send email. See [mail.md](mail.md). |
| `CAMPFIRE_SMTP_FROM` | `Campfire <campfire@HOST>` | The sender, for the host of the base url. |
| `CAMPFIRE_SMTP_HOSTNAME` | the host of the base url | The name that EHLO says. A base url with an IPv6 address needs this and `CAMPFIRE_SMTP_FROM`. |
| `CAMPFIRE_MAIL_QUEUE_SIZE` | `32` | Emails that may wait to be sent, 1 to 1024. Ignored when email is off. |

A `CAMPFIRE_BASE_URL` on `http://` for a host that is not this machine is warned about at start,
and refused when `CAMPFIRE_SECURE_COOKIES` is true.

## Health

`GET /health` answers `{"schema_version":N,"status":"ok"}` without a sign-in.

## Data folder and database

Start-up makes the data folder and its missing parents with mode 0700 (the database holds password
digests and tokens, and SQLite makes the file with the umask), and leaves a folder that exists as
it is.

The default database url turns on WAL mode and foreign keys. `fts5=required` stops start-up when
the system SQLite has no FTS5, which message search needs. A url with `foreign_keys=off` is refused,
since the schema relies on cascades.

At start-up the app runs the migrations that the database has not seen
(`src/campfire/repo/migrations.agc`) and prints `database: schema version N, migrations applied:
M`. If the database cannot be opened or migrated it exits with code 1 and a message that names the
variable.

Run one instance at a time per database: migrations run from one process, and two started together
make one of them fail on `schema_migrations`.

Back up with `VACUUM INTO`, or copy the file after the app stops: while it runs, recent writes may
live in the `-wal` file.

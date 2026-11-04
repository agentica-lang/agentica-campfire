# Configuration

The app reads everything from the environment (`src/campfire/config.agc`). A bad value stops
start-up with a message that names the variable.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CAMPFIRE_SESSION_SECRET` | none, required | Signs the session cookie; at least 32 bytes. Keep it out of the repository and the image, and use the same value on every start (a new one signs everybody out). |
| `CAMPFIRE_SECURE_COOKIES` | `false` | `true` behind HTTPS: the cookie is `Secure` and named `__Host-session_token` (else `session_token`), so a browser refuses it over plain HTTP. The first line of output says which. |
| `CAMPFIRE_HOST` | `127.0.0.1` | Address to listen on. |
| `CAMPFIRE_PORT` | `3000` | 0 to 65535. `0` picks a free port; the last line of output says which. |
| `CAMPFIRE_DATA_DIR` | `data` | Folder for the files of the app. No `?` in it. |
| `CAMPFIRE_DATABASE_URL` | `sqlite:DATA_DIR/campfire.db?fts5=required` | Another [agentica-db SQLite url](https://agentica-lang.github.io/agentica-db/guide/sqlite/). |
| `CAMPFIRE_DB_POOL_SIZE` | `0` | Database connections that the requests share: `0` takes the size of the database (4 for SQLite), else 3 to 64. At least 3, since up to two sign-ins hash a password at a time while they hold a connection. |
| `CAMPFIRE_DB_CHECKOUT_MS` | `3000` | How long a request waits for a free connection, 1 to 60000. After that it is answered `503` with `Retry-After: 1`. |
| `CAMPFIRE_BCRYPT_LIBRARY` | unset | A path or name of a library that exports `crypt_r` with bcrypt (a libxcrypt build), for checking the bcrypt digests of a Rails Campfire. Unset: `libcrypt.so.1` on Linux, and none on macOS and Windows, where this is how to name one. A library that cannot be used does not stop the app, it fails the sign-in of people with a bcrypt digest (see [security.md](security.md)). |
| `CAMPFIRE_BASE_URL` | unset | Public address: a scheme, a host and maybe a port, no path (`https://campfire.example.com`). Required with `CAMPFIRE_SMTP_URL`. The join link starts with it. |
| `CAMPFIRE_SMTP_URL` | unset (no email) | How to send email. See [mail.md](mail.md). |
| `CAMPFIRE_SMTP_FROM` | `Campfire <campfire@HOST>` | The sender, for the host of the base url. |
| `CAMPFIRE_SMTP_HOSTNAME` | the host of the base url | The name that EHLO says. A base url with an IPv6 address needs this and `CAMPFIRE_SMTP_FROM`. |
| `CAMPFIRE_MAIL_QUEUE_SIZE` | `32` | Emails that may wait to be sent, 1 to 1024. Ignored when email is off. |

Any `http://` `CAMPFIRE_BASE_URL` is refused when `CAMPFIRE_SECURE_COOKIES` is true, even for this
machine. Without secure cookies, one for a host that is not this machine is warned about at start
when email is on.

## Health

`GET /health` answers `{"schema_version":N,"status":"ok"}` without a sign-in. `GET /up` answers `200`
with the green page of Rails (`background-color: green`), also without one: it is the check that the
Rails Campfire benchmark harness waits for.

## Data folder and database

Start-up makes the data folder and its missing parents with mode 0700 (the database holds password
digests and tokens, and SQLite makes the file with the umask), and leaves a folder that exists as
it is.

agentica-db turns on WAL mode and foreign keys for any SQLite url. The default url has
`fts5=required`, which stops start-up when the system SQLite has no FTS5 (message search needs it);
add it to a custom url too. A url with `foreign_keys=off` is refused, since the schema relies on
cascades.

The app opens its connections once, at start-up, and lends one to each request (agentica-db `DbPool`).
A url that does not open stops the start. Put `timeout_ms` in the url to bound each statement
(under 30 s, the time a request may hold a connection); a statement that runs over it is answered `503` too.

At start-up the app runs the migrations that the database has not seen
(`src/campfire/repo/migrations.agc`) and prints `database: schema version N, migrations applied:
M`. If the database cannot be opened or migrated it exits with code 1 and a message that names the
variable.

Run one instance at a time per database: migrations run from one process, and two started together
make one of them fail on `schema_migrations`.

Back up with `VACUUM INTO`, or copy the file after the app stops: while it runs, recent writes may
live in the `-wal` file.

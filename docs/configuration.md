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
| `CAMPFIRE_CACHE_MB` | `64` | The megabytes of the cache of rendered messages (the room page and the older messages), 0 to 4096; `0` turns it off. The pages are the same bytes with it on and off. It lives in memory, so a restart empties it. A message takes about a kilobyte. When the messages in use outgrow it, one request pays for dropping the oldest generation, about 5 µs an entry (roughly 100 to 250 ms at 64 MB), and the others go on. |
| `CAMPFIRE_RESPONSE_CACHE_MB` | `64` | The megabytes of the cache of whole pages (the room page, the older messages, the sidebar and the search, one entry for each person, room and `?before=` or query), and of the people of the sessions, 0 to 4096; `0` turns it off. It is the setting of the same name of Rails Campfire. A page of 40 messages is about 16 KB. Any commit to the database, by any program, makes the next request build its page again, so a page is never stale; the old ones are dropped when the cache needs room (see [Rooms and messages](rooms.md#messages)). It lives in memory, and it takes one more connection to the database, which only reads `PRAGMA data_version`. |
| `CAMPFIRE_SEARCH_PAGES` | `8` | How many search pages one person keeps in the cache of whole pages, 1 to 64. A search has no cursor to bound it, so each person has this many places, chosen by the words of the query; a query that falls in a place takes it over, and a flood of queries can only write over the pages of the one who sends them. Unused when `CAMPFIRE_RESPONSE_CACHE_MB` is `0`. |
| `CAMPFIRE_SESSION_CACHE_MB` | `4` | The megabytes of the store that keeps the person of each session for one version of the database, 1 to 1024, apart from the pages so that they cannot push a session out. A person takes about a hundred bytes for every version. Unused when `CAMPFIRE_RESPONSE_CACHE_MB` is `0`. |
| `CAMPFIRE_MAX_CONNECTIONS` | `4096` | The connections that the server holds at once, 16 to 65535. A tab that has `/cable` open keeps one for as long as it is open, so set it above the tabs that may be connected and the requests at the same time. A request that finds the limit reached waits for a connection to end. About 100 KiB of memory per connected tab. |
| `CAMPFIRE_BCRYPT_LIBRARY` | unset | A path or name of a library that exports `crypt_r` with bcrypt (a libxcrypt build), for checking the bcrypt digests of a Rails Campfire. Unset: `libcrypt.so.1` on Linux, and none on macOS and Windows, where this is how to name one. A library that cannot be used does not stop the app, it fails the sign-in of people with a bcrypt digest (see [security.md](security.md)). |
| `SECRET_KEY_BASE` | unset | The secret of a Rails Campfire. It checks the avatar links (`/users/TOKEN/avatar`, a Rails `signed_id`; see [security.md](security.md)). Unset: every avatar link is `404`. Keep it as secret as the session secret. |
| `CAMPFIRE_STORAGE_DIR` | `DATA_DIR/files` | The folder of the files of Active Storage, in the `xx/yy/KEY` folders that the Disk service of Rails writes (`/rails/storage/files` in the Rails image). Avatars are read from it; nothing writes to it. |
| `CAMPFIRE_ASSETS_DIR` | `public/assets` | The folder served under `/assets/` (the stylesheet). It must be a folder, or start-up stops. A relative path is from where the program runs. |
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
(`src/campfire/repo/migrations.agc`, one file per migration in `migrations/`) and prints `database:
schema version N, migrations applied: M`. If the database cannot be opened or migrated it exits
with code 1 and a message that names the variable.

The schema is the one of a Rails Campfire (`db/schema.rb` of basecamp/once-campfire at 90b3300),
table by table, as step by step the app moves to it; `accounts`, `users` and `sessions` are there
already (see [people.md](people.md)). A database that Rails made, which has the table
`ar_internal_metadata`, is opened as it is: no migration runs, nothing is recorded, and the only
thing added is the table `password_resets`, which Rails has not. The app prints `database: made by
Rails, opened as it is, schema version V` (V is the last version Rails recorded) and `/health`
reports V. The rooms, memberships, messages, rich texts and search index are the Rails tables too
(`rooms.type` is `Rooms::Open`, `Rooms::Closed` or `Rooms::Direct`), so the rooms of a database made
by Rails work on it. The app keeps one table of its own, `password_resets`, in the list of migrations
for a database it makes, and adds it with `if not exists` to a database that Rails made.

At the start the app checks that such a database has the columns that it reads (`users.status`,
`rooms.type`, `messages.client_message_id`, `message_search_index.body`...) and stops, naming the first
one missing, when one is not there. A database that the app made before its history was rewritten to
the Rails schema (it has `schema_migrations`, and neither `ar_internal_metadata` nor
`agentica_schema_migrations`) also stops the start: delete the file and start again, since there has
been no release to convert from.

A database that the app made between the people step and the rooms step (before the rooms moved to
the Rails schema) fails at start with a checksum error and must be deleted, since there has been no
release to convert from.

The history of the app is the table `agentica_schema_migrations`, not `schema_migrations`, which
Rails owns. A database that the app makes never has `ar_internal_metadata` (that table is what tells
the two apart), nor `schema_migrations`.

Run one instance at a time per database: migrations run from one process, and two started together
make one of them fail on `agentica_schema_migrations`.

Back up with `VACUUM INTO`, or copy the file after the app stops: while it runs, recent writes may
live in the `-wal` file.

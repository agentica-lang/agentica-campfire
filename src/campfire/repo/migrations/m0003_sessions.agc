## The `sessions` table of a Rails Campfire: a row per sign-in, with the random `token` that the cookie carries. The
## key to `users` has no cascade, as in Rails: whoever deletes a user (the app never does) deletes their sessions
## first.

import Migrate from "pkg/db/migrate"

## Migration 3: create sessions.
def migration() -> Migrate.Migration
  Migrate.sql(
    3,
    "create sessions",
    [
      sessions(),
      "create unique index index_sessions_on_token on sessions (token)",
      "create index index_sessions_on_user_id on sessions (user_id)",
    ],
  )
end

private

def sessions() -> String
  <<~SQL
    create table sessions (
      id integer primary key autoincrement not null,
      created_at datetime(6) not null,
      ip_address varchar,
      last_active_at datetime(6) not null,
      token varchar not null,
      updated_at datetime(6) not null,
      user_agent varchar,
      user_id integer not null,
      foreign key (user_id) references users (id)
    )
  SQL
end

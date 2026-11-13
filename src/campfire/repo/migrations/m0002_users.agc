## The `users` table of a Rails Campfire. `role` is 0 member, 1 administrator, 2 bot and `status` is 0 active, 1
## deactivated, 2 banned (`rails.agc` names them). A bot has a `bot_token` and no email or password; a person has both.
## Rails keeps no check of that in the table, and nor does this: the code that makes a user is what keeps it. The
## unique index of `email_address` compares bytes, so the app stores an address in lower case and looks it up so.

import Migrate from "pkg/db/migrate"

## Migration 2: create users.
def migration() -> Migrate.Migration
  Migrate.sql(
    2,
    "create users",
    [
      users(),
      "create unique index index_users_on_bot_token on users (bot_token)",
      "create unique index index_users_on_email_address on users (email_address)",
    ],
  )
end

private

def users() -> String
  <<~SQL
    create table users (
      id integer primary key autoincrement not null,
      bio text,
      bot_token varchar,
      created_at datetime(6) not null,
      email_address varchar,
      name varchar not null,
      password_digest varchar,
      role integer default 0 not null,
      status integer default 0 not null,
      updated_at datetime(6) not null
    )
  SQL
end

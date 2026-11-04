## The `accounts` table of a Rails Campfire (`db/schema.rb` of basecamp/once-campfire at 90b3300), written as Rails'
## SQLite adapter writes it. The app has one account: `singleton_guard` is always 0 and its unique index lets in one
## row. `custom_styles` and `settings` are Rails' own, which the app does not read yet.

import Migrate from "pkg/db/migrate"

## Migration 1: create accounts.
export def migration() -> Migrate.Migration
  return Migrate.sql(
    1,
    "create accounts",
    [accounts(), "create unique index index_accounts_on_singleton_guard on accounts (singleton_guard)"],
  )
end

def accounts() -> String
  return <<~SQL
    create table accounts (
      id integer primary key autoincrement not null,
      created_at datetime(6) not null,
      custom_styles text,
      join_code varchar not null,
      name varchar not null,
      settings json,
      singleton_guard integer default 0 not null,
      updated_at datetime(6) not null
    )
  SQL
end

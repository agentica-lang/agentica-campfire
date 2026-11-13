## The `bans` table of a Rails Campfire: an IP address that a banned person came from.

import Migrate from "pkg/db/migrate"

## Migration 12: create bans.
def migration() -> Migrate.Migration
  Migrate.sql(
    12,
    "create bans",
    [
      bans(),
      "create index index_bans_on_ip_address on bans (ip_address)",
      "create index index_bans_on_user_id on bans (user_id)",
    ],
  )
end

private

def bans() -> String
  <<~SQL
    create table bans (
      id integer primary key autoincrement not null,
      created_at datetime(6) not null,
      ip_address varchar not null,
      updated_at datetime(6) not null,
      user_id integer not null,
      foreign key (user_id) references users (id)
    )
  SQL
end

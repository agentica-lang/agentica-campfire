## The `rooms` table of a Rails Campfire. `type` is the class of the single-table inheritance (`Rooms::Open`,
## `Rooms::Closed` or `Rooms::Direct`, named in `rails.agc`), and a direct room has no `name`. Rails has no index on it
## and no key from `creator_id`: the lookups of the app go through `memberships`.

import Migrate from "pkg/db/migrate"

## Migration 4: create rooms.
export def migration() -> Migrate.Migration
  return Migrate.sql(4, "create rooms", [rooms()])
end

def rooms() -> String
  return <<~SQL
    create table rooms (
      id integer primary key autoincrement not null,
      created_at datetime(6) not null,
      creator_id bigint not null,
      name varchar,
      type varchar not null,
      updated_at datetime(6) not null
    )
  SQL
end

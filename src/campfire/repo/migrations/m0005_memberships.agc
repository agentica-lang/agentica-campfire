## `unread_at` is set when a message arrives while the person is away. `connections` counts the open tabs, so it
## never goes below 0. The unique pair also serves the lookups by room.

import Migrate from "pkg/db/migrate"
import Rails from "../rails"

## Migration 5: create memberships.
export def migration() -> Migrate.Migration
  return Migrate.sql(
    5,
    "create memberships",
    [memberships(), "create index memberships_user_id on memberships (user_id)"],
  )
end

def memberships() -> String
  return <<~SQL
    create table memberships (
      id integer primary key autoincrement,
      room_id integer not null references rooms (id) on delete cascade,
      user_id integer not null references users (id) on delete cascade,
      involvement text not null default 'mentions'
        check (involvement in ('invisible', 'nothing', 'mentions', 'everything')),
      unread_at text,
      connections integer not null default 0 check (connections >= 0),
      created_at text not null default (#{Rails.NOW}),
      updated_at text not null default (#{Rails.NOW}),
      unique (room_id, user_id)
    )
  SQL
end

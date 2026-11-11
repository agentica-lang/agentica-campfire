## The `memberships` table of a Rails Campfire: who is in which room. `involvement` is one of `invisible`, `nothing`,
## `mentions` or `everything` (text, as Rails' enum writes it). `unread_at` is set when a message arrives while the
## person is away, and `connections` counts the open tabs (`connected_at` is when the first one opened). Rails has no
## key to `rooms` or `users` and no check on these, so the code that writes a row is what keeps them right. The unique
## pair also serves the lookups by room.

import Migrate from "pkg/db/migrate"

## Migration 5: create memberships.
export def migration() -> Migrate.Migration
  Migrate.sql(
    5,
    "create memberships",
    [
      memberships(),
      "create index index_memberships_on_room_id on memberships (room_id)",
      "create index index_memberships_on_room_id_and_created_at on memberships (room_id, created_at)",
      "create unique index index_memberships_on_room_id_and_user_id on memberships (room_id, user_id)",
      "create index index_memberships_on_user_id on memberships (user_id)",
    ],
  )
end

def memberships() -> String
  <<~SQL
    create table memberships (
      id integer primary key autoincrement not null,
      connected_at datetime(6),
      connections integer default 0 not null,
      created_at datetime(6) not null,
      involvement varchar default 'mentions',
      room_id integer not null,
      unread_at datetime(6),
      updated_at datetime(6) not null,
      user_id integer not null
    )
  SQL
end

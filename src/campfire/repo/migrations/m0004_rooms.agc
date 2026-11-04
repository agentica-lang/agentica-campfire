## A direct room has no name; the other kinds need one.

import Migrate from "pkg/db/migrate"
import Rails from "../rails"

## Migration 4: create rooms.
export def migration() -> Migrate.Migration
  return Migrate.sql(4, "create rooms", [rooms(), "create index rooms_creator_id on rooms (creator_id)"])
end

def rooms() -> String
  return <<~SQL
    create table rooms (
      id integer primary key autoincrement,
      name text,
      kind text not null default 'open' check (kind in ('open', 'closed', 'direct')),
      creator_id integer not null references users (id),
      created_at text not null default (#{Rails.NOW}),
      updated_at text not null default (#{Rails.NOW}),
      check (kind = 'direct' or name is not null)
    )
  SQL
end

## The `searches` table of a Rails Campfire: the recent queries of a person.

import Migrate from "pkg/db/migrate"

## Migration 13: create searches.
export def migration() -> Migrate.Migration
  return Migrate.sql(
    13,
    "create searches",
    [searches(), "create index index_searches_on_user_id on searches (user_id)"],
  )
end

def searches() -> String
  return <<~SQL
    create table searches (
      id integer primary key autoincrement not null,
      created_at datetime(6) not null,
      query varchar not null,
      updated_at datetime(6) not null,
      user_id integer not null,
      foreign key (user_id) references users (id)
    )
  SQL
end

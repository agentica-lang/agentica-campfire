## The `boosts` table of a Rails Campfire: a short reaction (`content` is at most 16 characters in Rails, as
## `varchar(16)`, which SQLite does not enforce) of a person to a message.

import Migrate from "pkg/db/migrate"

## Migration 8: create boosts.
def migration() -> Migrate.Migration
  Migrate.sql(
    8,
    "create boosts",
    [
      boosts(),
      "create index index_boosts_on_booster_id on boosts (booster_id)",
      "create index index_boosts_on_message_id on boosts (message_id)",
    ],
  )
end

private

def boosts() -> String
  <<~SQL
    create table boosts (
      id integer primary key autoincrement not null,
      booster_id integer not null,
      content varchar(16) not null,
      created_at datetime(6) not null,
      message_id integer not null,
      updated_at datetime(6) not null,
      foreign key (message_id) references messages (id)
    )
  SQL
end

import Migrate from "pkg/db/migrate"
import Rails from "../rails"

## Migration 7: create boosts.
export def migration() -> Migrate.Migration
  return Migrate.sql(
    7,
    "create boosts",
    [
      boosts(),
      "create index boosts_message_id on boosts (message_id)",
      "create index boosts_booster_id on boosts (booster_id)",
    ],
  )
end

def boosts() -> String
  return <<~SQL
    create table boosts (
      id integer primary key autoincrement,
      message_id integer not null references messages (id) on delete cascade,
      booster_id integer not null references users (id),
      content text not null check (length(content) > 0),
      created_at text not null default (#{Rails.NOW}),
      updated_at text not null default (#{Rails.NOW})
    )
  SQL
end

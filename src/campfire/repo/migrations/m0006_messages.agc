## `client_message_id` is the id that the browser made for a message it has not heard back about: unique per creator,
## so that a retry after a lost reply is refused and not stored twice. A page of a room reads `where room_id = ? and
## id < ? order by id desc limit N`, served by the index on (room_id, id). Page by id, never by `created_at`: several
## messages can share a millisecond, and `created_at < ?` would skip the ones that tie with the cursor.

import Migrate from "pkg/db/migrate"
import Rails from "../rails"

## Migration 6: create messages.
export def migration() -> Migrate.Migration
  return Migrate.sql(
    6,
    "create messages",
    [
      messages(),
      "create index messages_room_id_id on messages (room_id, id)",
      "create unique index messages_creator_id_client_message_id on messages (creator_id, client_message_id)",
    ],
  )
end

def messages() -> String
  return <<~SQL
    create table messages (
      id integer primary key autoincrement,
      room_id integer not null references rooms (id) on delete cascade,
      creator_id integer not null references users (id),
      body text not null,
      client_message_id text not null,
      created_at text not null default (#{Rails.NOW}),
      updated_at text not null default (#{Rails.NOW})
    )
  SQL
end

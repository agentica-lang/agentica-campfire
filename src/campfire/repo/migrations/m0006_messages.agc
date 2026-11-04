## The `messages` table of a Rails Campfire. It has no body: the text is HTML in `action_text_rich_texts` (the next
## migration), which is how Action Text keeps it. `client_message_id` is the id that the browser made for a message, for
## the DOM id of its optimistic copy: there is no unique index on it (Rails has none), so the app does not drop a
## message that repeats one.
##
## A page of a room is read by `created_at`, as Rails orders it, and not by `id`: the messages of a database that Rails
## seeded can be inserted in an order that is not the order of their time. Ties go by `id` (`Rooms.page`).

import Migrate from "pkg/db/migrate"

## Migration 6: create messages.
export def migration() -> Migrate.Migration
  return Migrate.sql(
    6,
    "create messages",
    [
      messages(),
      "create index index_messages_on_creator_id on messages (creator_id)",
      "create index index_messages_on_room_id on messages (room_id)",
    ],
  )
end

def messages() -> String
  return <<~SQL
    create table messages (
      id integer primary key autoincrement not null,
      client_message_id varchar not null,
      created_at datetime(6) not null,
      creator_id integer not null,
      room_id integer not null,
      updated_at datetime(6) not null,
      foreign key (room_id) references rooms (id),
      foreign key (creator_id) references users (id)
    )
  SQL
end

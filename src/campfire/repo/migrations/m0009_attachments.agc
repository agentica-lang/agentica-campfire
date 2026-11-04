## One file per message, stored on disk under `key`; the metadata is here. `width` and `height` are for images.

import Migrate from "pkg/db/migrate"
import Rails from "../rails"

## Migration 9: create attachments.
export def migration() -> Migrate.Migration
  return Migrate.sql(9, "create attachments", [attachments()])
end

def attachments() -> String
  return <<~SQL
    create table attachments (
      id integer primary key autoincrement,
      message_id integer not null unique references messages (id) on delete cascade,
      key text not null unique,
      filename text not null,
      content_type text not null,
      byte_size integer not null check (byte_size >= 0),
      checksum text not null,
      width integer,
      height integer,
      created_at text not null default (#{Rails.NOW})
    )
  SQL
end

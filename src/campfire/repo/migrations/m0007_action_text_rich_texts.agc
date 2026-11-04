## The `action_text_rich_texts` table of a Rails Campfire. The body of a message is the row with `record_type`
## `Message`, `name` `body` and `record_id` the message's id: HTML, which the app writes cleaned by
## `HtmlSanitizer.sanitize` and cleans again when it reads (a row that Rails wrote was not cleaned by this app). The
## unique index lets in one body per record.

import Migrate from "pkg/db/migrate"

## Migration 7: create action text rich texts.
export def migration() -> Migrate.Migration
  return Migrate.sql(
    7,
    "create action text rich texts",
    [
      rich_texts(),
      "create unique index index_action_text_rich_texts_uniqueness " +
      "on action_text_rich_texts (record_type, record_id, name)",
    ],
  )
end

def rich_texts() -> String
  return <<~SQL
    create table action_text_rich_texts (
      id integer primary key autoincrement not null,
      body text,
      created_at datetime(6) not null,
      name varchar not null,
      record_id bigint not null,
      record_type varchar not null,
      updated_at datetime(6) not null
    )
  SQL
end

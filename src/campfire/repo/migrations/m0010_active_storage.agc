## The three tables of Active Storage as a Rails Campfire has them: `active_storage_blobs` (a stored file: its `key`,
## name, type and size), `active_storage_attachments` (which record has which blob, by `record_type`, `record_id` and
## `name`) and `active_storage_variant_records` (a processed copy of an image). Rails keeps the avatar of a user and the
## file of a message this way. The keys to the blobs have no cascade.

import Migrate from "pkg/db/migrate"

## Migration 10: create active storage.
export def migration() -> Migrate.Migration
  return Migrate.sql(
    10,
    "create active storage",
    [
      blobs(),
      attachments(),
      variant_records(),
      "create index index_active_storage_attachments_on_blob_id on active_storage_attachments (blob_id)",
      "create unique index index_active_storage_attachments_uniqueness on active_storage_attachments (record_type, record_id, name, blob_id)",
      "create unique index index_active_storage_blobs_on_key on active_storage_blobs (key)",
      "create unique index index_active_storage_variant_records_uniqueness on active_storage_variant_records (blob_id, variation_digest)",
    ],
  )
end

def blobs() -> String
  return <<~SQL
    create table active_storage_blobs (
      id integer primary key autoincrement not null,
      byte_size bigint not null,
      checksum varchar,
      content_type varchar,
      created_at datetime(6) not null,
      filename varchar not null,
      key varchar not null,
      metadata text,
      service_name varchar not null
    )
  SQL
end

def attachments() -> String
  return <<~SQL
    create table active_storage_attachments (
      id integer primary key autoincrement not null,
      blob_id bigint not null,
      created_at datetime(6) not null,
      name varchar not null,
      record_id bigint not null,
      record_type varchar not null,
      foreign key (blob_id) references active_storage_blobs (id)
    )
  SQL
end

def variant_records() -> String
  return <<~SQL
    create table active_storage_variant_records (
      id integer primary key autoincrement not null,
      blob_id bigint not null,
      variation_digest varchar not null,
      foreign key (blob_id) references active_storage_blobs (id)
    )
  SQL
end

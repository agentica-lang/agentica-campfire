## The `webhooks` table of a Rails Campfire: the URL that a bot posts its new messages to, if it has one. Rails has no
## unique index on `user_id`, so the code that makes one keeps a bot to one.

import Migrate from "pkg/db/migrate"

## Migration 11: create webhooks.
def migration() -> Migrate.Migration
  Migrate.sql(11, "create webhooks", [webhooks(), "create index index_webhooks_on_user_id on webhooks (user_id)"])
end

private

def webhooks() -> String
  <<~SQL
    create table webhooks (
      id integer primary key autoincrement not null,
      created_at datetime(6) not null,
      updated_at datetime(6) not null,
      url varchar,
      user_id integer not null,
      foreign key (user_id) references users (id)
    )
  SQL
end

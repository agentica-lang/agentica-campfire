## The URL that a bot posts its new messages to, if it has one.

import Migrate from "pkg/db/migrate"
import Rails from "../rails"

## Migration 10: create webhooks.
export def migration() -> Migrate.Migration
  return Migrate.sql(10, "create webhooks", [webhooks()])
end

def webhooks() -> String
  return <<~SQL
    create table webhooks (
      id integer primary key autoincrement,
      user_id integer not null unique references users (id) on delete cascade,
      url text not null,
      created_at text not null default (#{Rails.NOW}),
      updated_at text not null default (#{Rails.NOW})
    )
  SQL
end

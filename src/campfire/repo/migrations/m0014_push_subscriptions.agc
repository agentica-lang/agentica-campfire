## The `push_subscriptions` table of a Rails Campfire: a browser that a person asked to be notified in (Web Push). The
## app does not send push yet; the table is here so that the schema is Rails'.

import Migrate from "pkg/db/migrate"

## Migration 14: create push subscriptions.
def migration() -> Migrate.Migration
  Migrate.sql(
    14,
    "create push subscriptions",
    [
      push_subscriptions(),
      "create index idx_on_endpoint_p256dh_key_auth_key_7553014576 " +
      "on push_subscriptions (endpoint, p256dh_key, auth_key)",
      "create index index_push_subscriptions_on_user_id on push_subscriptions (user_id)",
    ],
  )
end

private

def push_subscriptions() -> String
  <<~SQL
    create table push_subscriptions (
      id integer primary key autoincrement not null,
      auth_key varchar,
      created_at datetime(6) not null,
      endpoint varchar,
      p256dh_key varchar,
      updated_at datetime(6) not null,
      user_agent varchar,
      user_id integer not null,
      foreign key (user_id) references users (id)
    )
  SQL
end

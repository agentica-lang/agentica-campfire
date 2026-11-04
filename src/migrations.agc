## The schema of the app, as ordered migrations for `Migrate.up` (agentica-db). One migration per table, numbered 1, 2,
## 3...: never edit one that has shipped, add the next number (`Migrate` refuses a changed or renamed one).
##
## Timestamps are UTC text in ISO 8601 with milliseconds, which sorts like time and reads in a shell. The database
## fills them on insert; the app sets `updated_at` itself. Foreign keys are on (the driver's default, and
## `Database.migrate` refuses a connection that has them off): a user is never deleted, only deactivated, so the keys
## to `users` refuse a delete, and what hangs from a room or a message goes with it.

import Migrate from "pkg/db/migrate"

NOW = "(strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"

## Every migration of the schema, oldest first.
export def all() -> List[Migrate.Migration]
  return [
    Migrate.sql(1, "create accounts", [accounts()]),
    Migrate.sql(2, "create users", [users()]),
    Migrate.sql(3, "create sessions", [sessions(), "create index sessions_user_id on sessions (user_id)"]),
    Migrate.sql(4, "create rooms", [rooms(), "create index rooms_creator_id on rooms (creator_id)"]),
    Migrate.sql(5, "create memberships", [memberships(), "create index memberships_user_id on memberships (user_id)"]),
    Migrate.sql(
      6,
      "create messages",
      [
        messages(),
        "create index messages_room_id_id on messages (room_id, id)",
        "create unique index messages_creator_id_client_message_id on messages (creator_id, client_message_id)",
      ],
    ),
    Migrate.sql(
      7,
      "create boosts",
      [
        boosts(),
        "create index boosts_message_id on boosts (message_id)",
        "create index boosts_booster_id on boosts (booster_id)",
      ],
    ),
    Migrate.sql(
      8,
      "create message search index",
      [search_index(), search_insert_trigger(), search_update_trigger(), search_delete_trigger()],
    ),
    Migrate.sql(9, "create attachments", [attachments()]),
    Migrate.sql(10, "create webhooks", [webhooks()]),
    Migrate.sql(
      11,
      "create password resets",
      [password_resets(), "create index password_resets_user_id on password_resets (user_id)"],
    ),
  ]
end

## The version of the last migration: the schema version of a database that is up to date. The versions ascend in the
## list (`Migrate.up` refuses a list that does not).
export def latest() -> Int
  return all().last.version
end

# The single account of the app: `id = 1` is the only row that the check lets in.
def accounts() -> String
  return <<~SQL
    create table accounts (
      id integer primary key check (id = 1),
      name text not null,
      join_code text not null unique,
      created_at text not null default #{NOW},
      updated_at text not null default #{NOW}
    )
  SQL
end

# A bot has a token and no email or password; a person has an email and a password that are not empty, and no token.
# The check says each side in full, since a check that evaluates to NULL passes. The email is unique whatever its
# case.
def users() -> String
  return <<~SQL
    create table users (
      id integer primary key autoincrement,
      name text not null,
      email text collate nocase unique,
      password_digest text,
      role text not null default 'member' check (role in ('member', 'administrator', 'bot')),
      bio text,
      active integer not null default 1 check (active in (0, 1)),
      bot_token text unique,
      created_at text not null default #{NOW},
      updated_at text not null default #{NOW},
      check (
        (role = 'bot' and email is null and password_digest is null and bot_token is not null)
        or (role <> 'bot' and email is not null and length(email) > 0 and password_digest is not null
            and length(password_digest) > 0 and bot_token is null)
      )
    )
  SQL
end

def sessions() -> String
  return <<~SQL
    create table sessions (
      id integer primary key autoincrement,
      user_id integer not null references users (id) on delete cascade,
      token text not null unique,
      user_agent text,
      ip_address text,
      last_active_at text not null default #{NOW},
      created_at text not null default #{NOW},
      updated_at text not null default #{NOW}
    )
  SQL
end

# A direct room has no name; the other kinds need one.
def rooms() -> String
  return <<~SQL
    create table rooms (
      id integer primary key autoincrement,
      name text,
      kind text not null default 'open' check (kind in ('open', 'closed', 'direct')),
      creator_id integer not null references users (id),
      created_at text not null default #{NOW},
      updated_at text not null default #{NOW},
      check (kind = 'direct' or name is not null)
    )
  SQL
end

# `unread_at` is set when a message arrives while the person is away. `connections` counts the open tabs, so it
# never goes below 0. The unique pair also serves the lookups by room.
def memberships() -> String
  return <<~SQL
    create table memberships (
      id integer primary key autoincrement,
      room_id integer not null references rooms (id) on delete cascade,
      user_id integer not null references users (id) on delete cascade,
      involvement text not null default 'mentions'
        check (involvement in ('invisible', 'nothing', 'mentions', 'everything')),
      unread_at text,
      connections integer not null default 0 check (connections >= 0),
      created_at text not null default #{NOW},
      updated_at text not null default #{NOW},
      unique (room_id, user_id)
    )
  SQL
end

# `client_message_id` is the id that the browser made for a message it has not heard back about: unique per creator,
# so that a retry after a lost reply is refused and not stored twice. A page of a room reads `where room_id = ? and
# id < ? order by id desc limit N`, served by the index on (room_id, id). Page by id, never by `created_at`: several
# messages can share a millisecond, and `created_at < ?` would skip the ones that tie with the cursor.
def messages() -> String
  return <<~SQL
    create table messages (
      id integer primary key autoincrement,
      room_id integer not null references rooms (id) on delete cascade,
      creator_id integer not null references users (id),
      body text not null,
      client_message_id text not null,
      created_at text not null default #{NOW},
      updated_at text not null default #{NOW}
    )
  SQL
end

def boosts() -> String
  return <<~SQL
    create table boosts (
      id integer primary key autoincrement,
      message_id integer not null references messages (id) on delete cascade,
      booster_id integer not null references users (id),
      content text not null check (length(content) > 0),
      created_at text not null default #{NOW},
      updated_at text not null default #{NOW}
    )
  SQL
end

# Search is an FTS5 table over `messages.body` (it keeps no copy of the text), with the porter stemmer like upstream
# Campfire. Triggers keep it in step, so it is right whatever writes a message: a page, the bots API, an edit, or the
# delete of a whole room. The 'delete' command of an external content table needs the old text. Never write `insert or
# replace into messages`: SQLite does not fire the delete trigger for the row it replaces, so the old text stays in
# the index and corrupts it. An upsert (`on conflict do update`) fires the update trigger and is fine.
def search_index() -> String
  return <<~SQL
    create virtual table message_search_index using fts5(
      body,
      tokenize = 'porter',
      content = 'messages',
      content_rowid = 'id'
    )
  SQL
end

def search_insert_trigger() -> String
  return <<~SQL
    create trigger messages_search_insert after insert on messages begin
      insert into message_search_index (rowid, body) values (new.id, new.body);
    end
  SQL
end

def search_update_trigger() -> String
  return <<~SQL
    create trigger messages_search_update after update of body on messages begin
      insert into message_search_index (message_search_index, rowid, body) values ('delete', old.id, old.body);
      insert into message_search_index (rowid, body) values (new.id, new.body);
    end
  SQL
end

def search_delete_trigger() -> String
  return <<~SQL
    create trigger messages_search_delete after delete on messages begin
      insert into message_search_index (message_search_index, rowid, body) values ('delete', old.id, old.body);
    end
  SQL
end

# One file per message, stored on disk under `key`; the metadata is here. `width` and `height` are for images.
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
      created_at text not null default #{NOW}
    )
  SQL
end

# The URL that a bot posts its new messages to, if it has one.
def webhooks() -> String
  return <<~SQL
    create table webhooks (
      id integer primary key autoincrement,
      user_id integer not null unique references users (id) on delete cascade,
      url text not null,
      created_at text not null default #{NOW},
      updated_at text not null default #{NOW}
    )
  SQL
end

# A link in an email to reset a password. Only a hash of its token is kept, so a copy of the database does not give a
# link that works. The token is random and 256 bits, so a plain SHA-256 is enough (no slow hash). `used_at` is set by
# the one request that uses the link, which is what makes it single-use; the row stays for a while so that the next
# request for a link waits (see `Auth.request_password_reset`). It goes with its user.
def password_resets() -> String
  return <<~SQL
    create table password_resets (
      id integer primary key autoincrement,
      user_id integer not null references users (id) on delete cascade,
      token_digest text not null unique,
      expires_at text not null,
      used_at text,
      created_at text not null default #{NOW}
    )
  SQL
end

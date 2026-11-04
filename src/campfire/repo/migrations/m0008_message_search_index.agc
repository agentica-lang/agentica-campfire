## Search is an FTS5 table over `messages.body` (it keeps no copy of the text), with the porter stemmer like upstream
## Campfire. Triggers keep it in step, so it is right whatever writes a message: a page, the bots API, an edit, or the
## delete of a whole room. The 'delete' command of an external content table needs the old text. Never write `insert or
## replace into messages`: SQLite does not fire the delete trigger for the row it replaces, so the old text stays in
## the index and corrupts it. An upsert (`on conflict do update`) fires the update trigger and is fine.

import Migrate from "pkg/db/migrate"

## Migration 8: create message search index.
export def migration() -> Migrate.Migration
  return Migrate.sql(
    8,
    "create message search index",
    [search_index(), search_insert_trigger(), search_update_trigger(), search_delete_trigger()],
  )
end

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

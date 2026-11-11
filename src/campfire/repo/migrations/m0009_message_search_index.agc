## Search is a standalone FTS5 table, as Rails makes it: it keeps its own copy of the text (`body`, with the porter
## stemmer) and `rowid` is the id of the message. There are no triggers and it is not an external content table, since
## the text of a message is not in `messages`: the code that stores a message writes its plain text here in the same
## transaction (`Rooms.post`), and a database that Rails made has the same table, filled the same way.

import Migrate from "pkg/db/migrate"

## Migration 9: create message search index.
export def migration() -> Migrate.Migration
  Migrate.sql(
    9,
    "create message search index",
    ["create virtual table message_search_index using fts5 (body, tokenize=porter)"],
  )
end

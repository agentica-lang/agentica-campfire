Feature: The schema
  The tables of the app are the tables of a Rails Campfire as Rails writes them (`db/schema.rb` of basecamp/once-campfire
  at 90b3300): the same columns, types, indexes and keys, so a database that Rails made is the same schema. Role 0 is a
  member, 1 an administrator and 2 a bot; status 0 is active, 1 deactivated and 2 banned; `rooms.type` is `Rooms::Open`,
  `Rooms::Closed` or `Rooms::Direct`. The one table that Rails has not is `password_resets`. The keys are Rails' own:
  they refuse a row without its parent and a delete of a parent that still has rows, and there is no cascade.

  Background:
    Given an empty database
    And the database is migrated
    And I run the sql "insert into users (name, email_address, password_digest, role, created_at, updated_at) values ('Ana', 'ana@example.com', 'x', 1, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I run the sql "insert into rooms (name, type, creator_id, created_at, updated_at) values ('Lobby', 'Rooms::Open', 1, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"

  Scenario: The tables that Rails has are the tables that Rails makes
    Given a copy of the database made by Rails is next to it
    Then "accounts, users, sessions, rooms, memberships, messages, action_text_rich_texts, boosts, message_search_index, active_storage_blobs, active_storage_attachments, active_storage_variant_records, webhooks, bans, searches, push_subscriptions" are as Rails made them
    And the tables are those of Rails and "password_resets, agentica_schema_migrations"

  Scenario: The search index is its own table and nothing writes it for the app
    Then the query "select count(*) from sqlite_master where type = 'trigger'" gives 0
    When I run the sql "insert into message_search_index (rowid, body) values (1, 'The fire burns warm')"
    Then the query "select count(*) from message_search_index where message_search_index match 'burning'" gives 1
    When I run the sql "insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) values (1, 1, 'c1', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    Then the query "select count(*) from message_search_index" gives 1

  Scenario: A membership starts as Rails starts it
    When I run the sql "insert into memberships (room_id, user_id, created_at, updated_at) values (1, 1, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    Then the query "select count(*) from memberships where involvement = 'mentions' and connections = 0 and unread_at is null and connected_at is null" gives 1

  Scenario: A direct room needs no name
    When I run the sql "insert into rooms (type, creator_id, created_at, updated_at) values ('Rooms::Direct', 1, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    Then the query "select count(*) from rooms where name is null" gives 1

  # There has been no release, so the history was rewritten to the Rails schema (AGENTS.md). From the first release a
  # migration that has shipped is never edited: a database that ran it refuses the edited text and the app stops at
  # start-up. Change a table with a new migration, and add its row here.
  Scenario: The migrations keep the checksums they shipped with
    Then the recorded checksums are:
      | 1 | 2a318363b4ac8f0aac4fc4eaa0377ee5a6d481abb7df45646293cc598b99ff37 |
      | 2 | 15da351e5006a0fabc860b725a23dc52412f505880610aea237760ce3e02cd33 |
      | 3 | 299105c914cd1491e7b0b3c9540da9009c3173d15009c77ef4b891ecd57786e5 |
      | 4 | 229c52859052455a46a28345334db635fe8674f91099c9e3402de465ac971fb9 |
      | 5 | 7f2557fa092afa7c60e589a6d477d5c3d62572c2fe609da29be95716125e1181 |
      | 6 | 86cdbd4ae9e9601653e8de8efb2615a1e3c44839a89cdd2ff749855ff45759c5 |
      | 7 | ec0715276cac9edc45cce672c75c455ed7e5f3df779383e17d7e90d6dce01f1a |
      | 8 | 4a9be78ccef1b1d507f632cf6ff91c7859c32d533acf21a8c9beabf056d48031 |
      | 9 | 24138c938ca3601354bf9b86001d0d039c2e5a1e0000027102ee8710fae3c69f |
      | 10 | eceaf191c5b94629113cc6b2e13bffd7d8b88ea0074c61f8b05c8d61fae2bf37 |
      | 11 | e282d1c63e6a942872d773bb47378130f27190731f0c0ea040a1ce530a255910 |
      | 12 | dedd886e50eb0d276d57177db5f9a3de3539484137921f595b5011d5fed355dd |
      | 13 | 10106ef431781b119188ec9553153438ef7847fa9e477c59c365dd39152a5c8d |
      | 14 | 4e4e944d4e68db77814cb12278b2afd959bffa97318232af2f69cf01837495fe |
      | 15 | cc6d04cf16130392f1b926844315eaa996992a19a3f136cc6101563328d33cc1 |

  Scenario Outline: The database refuses a row that breaks a rule
    Given I run the sql "insert into memberships (room_id, user_id, created_at, updated_at) values (1, 1, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I run the sql "insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) values (1, 1, 'c1', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I run the sql "insert into action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at) values ('Message', 1, 'body', 'Hi', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I run the sql "insert into accounts (name, join_code, created_at, updated_at) values ('One', 'a', 'now', 'now')"
    And a bot "Bot" with the token "tok" exists
    And I run the sql "insert into password_resets (user_id, token_digest, expires_at) values (1, 'd1', '2030-01-01 00:00:00.000000')"
    And I run the sql "insert into sessions (user_id, token, last_active_at, created_at, updated_at) values (1, 's1', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    When I try the sql "<sql>"
    Then the sql fails with "<error>"

    Examples:
      | sql | error |
      | insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) values (9, 1, 'x', 'now', 'now') | FOREIGN KEY constraint failed |
      | insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) values (1, 9, 'x', 'now', 'now') | FOREIGN KEY constraint failed |
      | insert into memberships (room_id, user_id, created_at, updated_at) values (1, 1, 'now', 'now') | UNIQUE constraint failed |
      | insert into action_text_rich_texts (record_type, record_id, name, created_at, updated_at) values ('Message', 1, 'body', 'now', 'now') | UNIQUE constraint failed |
      | insert into rooms (name, creator_id, created_at, updated_at) values ('Odd', 1, 'now', 'now') | NOT NULL constraint failed |
      | delete from rooms where id = 1 | FOREIGN KEY constraint failed |
      | insert into password_resets (user_id, token_digest, expires_at) values (1, 'd1', 'x') | UNIQUE constraint failed |
      | insert into password_resets (user_id, token_digest, expires_at) values (9, 'd2', 'x') | FOREIGN KEY constraint failed |
      | insert into users (name, email_address, created_at, updated_at) values ('Bea', 'ana@example.com', 'now', 'now') | UNIQUE constraint failed |
      | insert into users (name, bot_token, created_at, updated_at) values ('Bot2', 'tok', 'now', 'now') | UNIQUE constraint failed |
      | insert into users (name, email_address) values ('Bea', 'bea@example.com') | NOT NULL constraint failed |
      | insert into accounts (name, join_code, created_at, updated_at) values ('Two', 'b', 'now', 'now') | UNIQUE constraint failed |
      | insert into sessions (user_id, token, last_active_at, created_at, updated_at) values (1, 's1', 'now', 'now', 'now') | UNIQUE constraint failed |
      | insert into sessions (user_id, token, last_active_at, created_at, updated_at) values (9, 's2', 'now', 'now', 'now') | FOREIGN KEY constraint failed |
      | delete from users where id = 1 | FOREIGN KEY constraint failed |

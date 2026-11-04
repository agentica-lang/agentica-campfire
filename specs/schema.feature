Feature: The schema
  The tables of the app. `accounts`, `users` and `sessions` are the tables of a Rails Campfire as Rails writes them
  (role 0 is a member, 1 an administrator and 2 a bot; status 0 is active, 1 deactivated and 2 banned), so a database
  that Rails made is the same schema; the rest are still the tables of this app until they move to the Rails schema.
  The rules that the database keeps: foreign keys, unique values, and a search index that follows the messages.

  Background:
    Given a fresh database
    And the database is migrated
    And I run the sql "insert into users (name, email_address, password_digest, role, created_at, updated_at) values ('Ana', 'ana@example.com', 'x', 1, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I run the sql "insert into rooms (name, kind, creator_id) values ('Lobby', 'open', 1)"

  Scenario: The search index follows the messages through an edit, a delete and the delete of a room
    When I run the sql "insert into messages (room_id, creator_id, body, client_message_id) values (1, 1, 'The fire burns warm', 'c1')"
    Then the query "select count(*) from message_search_index where message_search_index match 'burning'" gives 1
    When I run the sql "update messages set body = 'Only ashes' where id = 1"
    Then the query "select count(*) from message_search_index where message_search_index match 'burning'" gives 0
    And the query "select count(*) from message_search_index where message_search_index match 'ashes'" gives 1
    When I run the sql "insert into messages (room_id, creator_id, body, client_message_id) values (1, 1, 'Cold embers', 'c2')"
    And I run the sql "delete from messages where id = 1"
    Then the query "select count(*) from message_search_index where message_search_index match 'ashes'" gives 0
    When I run the sql "delete from rooms where id = 1"
    Then the query "select count(*) from messages" gives 0
    And the query "select count(*) from message_search_index where message_search_index match 'embers'" gives 0

  Scenario: Deleting a room deletes what hangs from it
    Given I run the sql "insert into memberships (room_id, user_id) values (1, 1)"
    And I run the sql "insert into messages (room_id, creator_id, body, client_message_id) values (1, 1, 'Hi', 'c1')"
    And I run the sql "insert into boosts (message_id, booster_id, content) values (1, 1, 'ok')"
    And I run the sql "insert into attachments (message_id, key, filename, content_type, byte_size, checksum) values (1, 'k1', 'a.txt', 'text/plain', 2, 'abc')"
    When I run the sql "delete from rooms where id = 1"
    Then the query "select count(*) from memberships" gives 0
    And the query "select count(*) from messages" gives 0
    And the query "select count(*) from boosts" gives 0
    And the query "select count(*) from attachments" gives 0
    And the query "select count(*) from users" gives 1

  Scenario: A direct room needs no name
    When I run the sql "insert into rooms (kind, creator_id) values ('direct', 1)"
    Then the query "select count(*) from rooms where name is null" gives 1

  # There has been no release, so the history was rewritten to the Rails schema (AGENTS.md). From the first release a
  # migration that has shipped is never edited: a database that ran it refuses the edited text and the app stops at
  # start-up. Change a table with a new migration, and add its row here.
  Scenario: The migrations keep the checksums they shipped with
    Then the recorded checksums are:
      | 1 | 2a318363b4ac8f0aac4fc4eaa0377ee5a6d481abb7df45646293cc598b99ff37 |
      | 2 | 15da351e5006a0fabc860b725a23dc52412f505880610aea237760ce3e02cd33 |
      | 3 | 299105c914cd1491e7b0b3c9540da9009c3173d15009c77ef4b891ecd57786e5 |
      | 4 | c475250e4a282dd48d6b51d584641673716efb1f3d9599873f3b9186b39fee73 |
      | 5 | 4890445ed12a696e092ad60be00387bf5f17df3f79033b1522a1201bbedd8406 |
      | 6 | 3347e60ff8daf49e697ebec9a96353f9663a770e44d1466eb11908bbcd026b00 |
      | 7 | bce9a5c75c5305f6af05d5e5149b20a57a02d98d07af4d963f1278fcec8ddc52 |
      | 8 | b44ac0593437668bb2af54fa31e7d6b9a2e809c8eb1f5d3290906cc7aed4c03d |
      | 9 | ea271c6f86a2e155c4a7d8b266dce4b5d0270e54ce86b8c374befa1f650ed0f5 |
      | 10 | 28172936eaad7f96e755b0eb5b2f08d30db11e711d0db0c96b5525eed9d512ee |
      | 11 | cc6d04cf16130392f1b926844315eaa996992a19a3f136cc6101563328d33cc1 |

  Scenario: The tables that Rails has are the tables that Rails makes
    Given a copy of the database made by Rails is next to it
    Then "accounts, users, sessions" are as Rails made them

  Scenario Outline: The database refuses a row that breaks a rule
    Given I run the sql "insert into memberships (room_id, user_id) values (1, 1)"
    And I run the sql "insert into messages (room_id, creator_id, body, client_message_id) values (1, 1, 'Hi', 'c1')"
    And I run the sql "insert into attachments (message_id, key, filename, content_type, byte_size, checksum) values (1, 'k1', 'a.txt', 'text/plain', 2, 'abc')"
    And I run the sql "insert into accounts (name, join_code, created_at, updated_at) values ('One', 'a', 'now', 'now')"
    And a bot "Bot" with the token "tok" exists
    And I run the sql "insert into webhooks (user_id, url) values (2, 'http://localhost/hook')"
    And I run the sql "insert into password_resets (user_id, token_digest, expires_at) values (1, 'd1', '2030-01-01 00:00:00.000000')"
    And I run the sql "insert into sessions (user_id, token, last_active_at, created_at, updated_at) values (1, 's1', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    When I try the sql "<sql>"
    Then the sql fails with "<error>"

    Examples:
      | sql | error |
      | insert into messages (room_id, creator_id, body, client_message_id) values (9, 1, 'x', 'c') | FOREIGN KEY constraint failed |
      | insert into messages (room_id, creator_id, body, client_message_id) values (1, 1, 'again', 'c1') | UNIQUE constraint failed |
      | insert into attachments (message_id, key, filename, content_type, byte_size, checksum) values (1, 'k2', 'b.txt', 'text/plain', 2, 'abc') | UNIQUE constraint failed |
      | insert into webhooks (user_id, url) values (2, 'http://localhost/other') | UNIQUE constraint failed |
      | insert into memberships (room_id, user_id) values (1, 1) | UNIQUE constraint failed |
      | insert into password_resets (user_id, token_digest, expires_at) values (1, 'd1', 'x') | UNIQUE constraint failed |
      | insert into password_resets (user_id, token_digest, expires_at) values (9, 'd2', 'x') | FOREIGN KEY constraint failed |
      | insert into memberships (room_id, user_id, involvement) values (1, 2, 'always') | CHECK constraint failed |
      | insert into boosts (message_id, booster_id, content) values (1, 1, '') | CHECK constraint failed |
      | insert into users (name, email_address, created_at, updated_at) values ('Bea', 'ana@example.com', 'now', 'now') | UNIQUE constraint failed |
      | insert into users (name, bot_token, created_at, updated_at) values ('Bot2', 'tok', 'now', 'now') | UNIQUE constraint failed |
      | insert into users (name, email_address) values ('Bea', 'bea@example.com') | NOT NULL constraint failed |
      | insert into accounts (name, join_code, created_at, updated_at) values ('Two', 'b', 'now', 'now') | UNIQUE constraint failed |
      | insert into sessions (user_id, token, last_active_at, created_at, updated_at) values (1, 's1', 'now', 'now', 'now') | UNIQUE constraint failed |
      | insert into sessions (user_id, token, last_active_at, created_at, updated_at) values (9, 's2', 'now', 'now', 'now') | FOREIGN KEY constraint failed |
      | insert into rooms (name, kind, creator_id) values ('Odd', 'secret', 1) | CHECK constraint failed |
      | insert into rooms (kind, creator_id) values ('open', 1) | CHECK constraint failed |
      | delete from users where id = 1 | FOREIGN KEY constraint failed |

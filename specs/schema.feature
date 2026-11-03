Feature: The schema
  The tables of the MVP, with the rules that the database keeps for the app: foreign keys, unique values, and a search
  index that follows the messages.

  Background:
    Given a fresh database
    And the database is migrated
    And I run the sql "insert into users (name, email, password_digest, role) values ('Ana', 'ana@example.com', 'x', 'administrator')"
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

  # A migration that has shipped is never edited (AGENTS.md): a database that ran it refuses the edited text and the
  # app stops at start-up. Change a table with a new migration, and add its row here.
  Scenario: The migrations keep the checksums they shipped with
    Then the recorded checksums are:
      | 1 | af7af0d87defddf570be7178ba471b4e4eb2dde1caba45d054a2122f934e9f29 |
      | 2 | e88000c35eb8945298a4a7e9a901a19d8b06be470c9a8a4ce9fd5f210eb4fc17 |
      | 3 | 29df2aa29112429ad597dbdd98a6a67b725d45d9633c14172ae7eb2464ff941c |
      | 4 | 957d3ff04ced3a511fc1f7c081a5aa2d16a96840f7db470d73f46129e5cdbcd5 |
      | 5 | 67982cfece565d07ef1a977bd074db00550959dcb2742d2584ca829056380ef3 |
      | 6 | d5f3b93af8d0511dec7908559fda97843238116047706c639bed493af5e68bf7 |
      | 7 | 915301bd098ddcc34b1b86d0e7e791ca54eb8cf6fc2f7dda380bca156532b1c1 |
      | 8 | b44ac0593437668bb2af54fa31e7d6b9a2e809c8eb1f5d3290906cc7aed4c03d |
      | 9 | 984c50d51fa1f18070d6edb70e1e9dbb3c63ef8e9a6ec15249206174f01ab14f |
      | 10 | be991ad069123d9bda2092dfe66a96a334471e6466400736538f674aeaeb2051 |

  Scenario Outline: The database refuses a row that breaks a rule
    Given I run the sql "insert into memberships (room_id, user_id) values (1, 1)"
    And I run the sql "insert into messages (room_id, creator_id, body, client_message_id) values (1, 1, 'Hi', 'c1')"
    And I run the sql "insert into attachments (message_id, key, filename, content_type, byte_size, checksum) values (1, 'k1', 'a.txt', 'text/plain', 2, 'abc')"
    And I run the sql "insert into users (name, role, bot_token) values ('Bot', 'bot', 'tok')"
    And I run the sql "insert into webhooks (user_id, url) values (2, 'http://localhost/hook')"
    When I try the sql "<sql>"
    Then the sql fails with "<error>"

    Examples:
      | sql | error |
      | insert into messages (room_id, creator_id, body, client_message_id) values (9, 1, 'x', 'c') | FOREIGN KEY constraint failed |
      | insert into messages (room_id, creator_id, body, client_message_id) values (1, 1, 'again', 'c1') | UNIQUE constraint failed |
      | insert into attachments (message_id, key, filename, content_type, byte_size, checksum) values (1, 'k2', 'b.txt', 'text/plain', 2, 'abc') | UNIQUE constraint failed |
      | insert into webhooks (user_id, url) values (2, 'http://localhost/other') | UNIQUE constraint failed |
      | insert into memberships (room_id, user_id) values (1, 1) | UNIQUE constraint failed |
      | insert into memberships (room_id, user_id, involvement) values (1, 2, 'always') | CHECK constraint failed |
      | insert into boosts (message_id, booster_id, content) values (1, 1, '') | CHECK constraint failed |
      | insert into users (name, email, password_digest) values ('Bea', 'ANA@example.com', 'x') | UNIQUE constraint failed |
      | insert into users (name, role) values ('Bea', 'member') | CHECK constraint failed |
      | insert into users (name, email, password_digest, role) values ('Bea', '', 'x', 'member') | CHECK constraint failed |
      | insert into users (name, email, password_digest, bot_token) values ('Bea', 'bea@example.com', 'x', 'tok2') | CHECK constraint failed |
      | insert into users (name, role) values ('Bot2', 'bot') | CHECK constraint failed |
      | insert into users (name, email, role, bot_token) values ('Bot2', 'bot2@example.com', 'bot', 'tok2') | CHECK constraint failed |
      | insert into accounts (id, name, join_code) values (2, 'Second', 'abc') | CHECK constraint failed |
      | insert into rooms (name, kind, creator_id) values ('Odd', 'secret', 1) | CHECK constraint failed |
      | insert into rooms (kind, creator_id) values ('open', 1) | CHECK constraint failed |
      | delete from users where id = 1 | FOREIGN KEY constraint failed |

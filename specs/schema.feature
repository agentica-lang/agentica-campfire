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
    And the database is removed

  Scenario Outline: The database refuses a row that breaks a rule
    Given I run the sql "insert into memberships (room_id, user_id) values (1, 1)"
    When I try the sql "<sql>"
    Then the sql fails with "<error>"
    And the database is removed

    Examples:
      | sql                                                                                                 | error                         |
      | insert into messages (room_id, creator_id, body, client_message_id) values (9, 1, 'x', 'c')         | FOREIGN KEY constraint failed |
      | insert into memberships (room_id, user_id) values (1, 1)                                            | UNIQUE constraint failed      |
      | insert into users (name, email, password_digest) values ('Bea', 'ANA@example.com', 'x')             | UNIQUE constraint failed      |
      | insert into users (name, role) values ('Bea', 'member')                                             | CHECK constraint failed       |
      | insert into accounts (id, name, join_code) values (2, 'Second', 'abc')                              | CHECK constraint failed       |
      | insert into rooms (name, kind, creator_id) values ('Odd', 'secret', 1)                              | CHECK constraint failed       |
      | delete from users where id = 1                                                                      | FOREIGN KEY constraint failed |

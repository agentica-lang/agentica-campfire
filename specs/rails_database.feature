Feature: A database that Rails made
  A database that a Rails Campfire made (it has `ar_internal_metadata`) is the schema of the app already, so the app
  opens it as it is: no migration runs, not even a history table, and the one thing added is the table of the password
  resets, which Rails has not. Its people sign in with
  the bcrypt digests that Rails wrote. `specs/fixtures/rails/campfire.sqlite3` is such a database, made by Rails
  itself from `db/schema.rb` at 90b3300 (`make.sh` makes it again). Its people: David, an administrator (user 1), JZ, a
  bot, Rita who is deactivated and Mallory who is banned; their password is `secret123456`. It has no rooms or
  messages: a scenario that needs them writes the rows as Rails does (a message is a row, its HTML body in
  `action_text_rich_texts`), and the app reads and writes them in the same tables.

  Background:
    Given bcrypt digests can be checked on this system
    And a fresh database
    And a database made by Rails
    And the app starts
    And the browser has no cookies

  Scenario: The app opens it as it is
    Then the app said "database: made by Rails, opened as it is, schema version 20251212154340"
    And the database does not have the table "agentica_schema_migrations"
    And the database has the tables:
      | password_resets |
    When I get "/health"
    Then the body contains "20251212154340"

  Scenario: A person signs in with their bcrypt digest, and the session is a row that Rails could read
    When I post to "/session" the form:
      | email_address | david@37signals.com |
      | password      | secret123456        |
    Then the status is 302
    And the header "set-cookie" contains "session_token="
    And the query "select count(*) from sessions where user_id = 1" gives 1
    And the query "select count(*) from sessions where user_id = 1 and length(token) = 64 and created_at like '____-__-__ __:__:__.______' and last_active_at like '____-__-__ __:__:__.______'" gives 1

  Scenario Outline: Whoever is not an active person does not sign in
    When I post to "/session" the form:
      | email_address | <email>      |
      | password      | secret123456 |
    Then the status is 422
    And the query "select count(*) from sessions" gives 1

    Examples:
      | email                                                                   |
      | rita-deactivated-00000000-0000-4000-8000-000000000000@37signals.com    |
      | mallory@example.com                                                     |

  Scenario: The account is the row that Rails made
    When "david@37signals.com" asks Accounts to "regenerate" the user 0
    Then the query "select count(*) from accounts where join_code <> 'CRMu-l8Ge-KB9B' and updated_at > '2026-03-01 09:00:00.123456'" gives 1
    When "david@37signals.com" asks Accounts to "deactivate" the user 2
    Then the query "select count(*) from users where id = 2 and status = 1" gives 1

  Scenario: A row that Rails stored in mixed case signs in with any case
    Given I run the sql "update users set email_address = 'David@37signals.com' where id = 1"
    When I post to "/session" the form:
      | email_address | DAVID@37signals.com |
      | password      | secret123456        |
    Then the status is 302
    And the query "select count(*) from users where email_address = 'David@37signals.com'" gives 1

  Scenario: Where two rows differ only in case, the one in lower case is the person, and else the oldest
    Given I run the sql "update users set email_address = 'David@37signals.com' where id = 1"
    And I run the sql "update users set email_address = 'david@37signals.com' where id = 2"
    When I post to "/session" the form:
      | email_address | David@37signals.com |
      | password      | secret123456        |
    Then the status is 302
    And the query "select count(*) from sessions where user_id = 2" gives 1
    Given the browser has no cookies
    And I run the sql "update users set email_address = 'DAVID@37signals.com' where id = 2"
    When I post to "/session" the form:
      | email_address | david@37signals.com |
      | password      | secret123456        |
    Then the status is 302
    And the query "select count(*) from sessions where user_id = 1" gives 1
    And the query "select count(*) from sessions where user_id = 2" gives 1

  Scenario: Joining with the email of a row that Rails stored in mixed case is refused
    Given I run the sql "update users set email_address = 'David@37signals.com' where id = 1"
    When I post to "/join/CRMu-l8Ge-KB9B" the form:
      | name     | Dave Two              |
      | email    | david@37signals.com   |
      | password | another long password |
    Then the status is 422
    And the body contains "An account with that email exists already"
    And the query "select count(*) from users" gives 5

  Scenario: The rooms and messages are the Rails tables: a page is paged by time and the body is cleaned
    Given I run the sql "insert into rooms (name, type, creator_id, created_at, updated_at) values ('Watercooler', 'Rooms::Closed', 1, '2026-03-01 09:00:00.123456', '2026-03-01 09:00:00.123456')"
    And I run the sql "insert into memberships (room_id, user_id, created_at, updated_at) values (1, 1, '2026-03-01 09:00:00.123456', '2026-03-01 09:00:00.123456')"
    And a message "<p>Later by time, first by id</p>" in the room 1 at "2026-03-01 09:30:00.000000"
    And a message "<p onclick=\"x()\">Earlier by time</p><script>alert(1)</script>" in the room 1 at "2026-03-01 09:10:00.000000"
    And I post to "/session" the form:
      | email_address | david@37signals.com |
      | password      | secret123456        |
    When I get "/"
    Then the body contains "Watercooler"
    When I get "/rooms/1"
    Then the status is 200
    And the body shows "<p>Earlier by time</p>" before "<p>Later by time, first by id</p>"
    And the body does not contain "onclick"
    And the body does not contain "alert(1)"
    When I post to "/rooms/1/messages" the form:
      | message[body]              | Posted into Rails |
      | message[client_message_id] | c-9               |
    Then the status is 302
    And the query "select count(*) from action_text_rich_texts where record_type = 'Message' and name = 'body' and record_id = 3 and body = 'Posted into Rails'" gives 1
    And the query "select count(*) from message_search_index where rowid = 3 and body = 'Posted into Rails'" gives 1
    And the query "select count(*) from messages where id = 3 and room_id = 1 and creator_id = 1 and client_message_id = 'c-9'" gives 1

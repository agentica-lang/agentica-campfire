Feature: A database that Rails made
  A database that a Rails Campfire made (it has `ar_internal_metadata`) is the schema of the app already, so the app
  opens it as it is: no migration runs, not even a history table, and the one thing added is the table of the password
  resets, which Rails has not. Its people sign in with
  the bcrypt digests that Rails wrote. `specs/fixtures/rails/campfire.sqlite3` is such a database, made by Rails
  itself from `db/schema.rb` at 90b3300 (`make.sh` makes it again). Its people: David, an administrator (user 1), JZ, a
  bot, Rita who is deactivated and Mallory who is banned; their password is `secret123456`. The rooms and messages of
  the app have not moved to the Rails schema yet, so the pages that show rooms do not work on such a database.

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

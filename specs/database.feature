Feature: The database and its migrations
  At start-up the app opens its SQLite database (CAMPFIRE_DATABASE_URL, a file in the data directory by default), runs
  the migrations that the database has not seen and only then listens. A start that cannot open or migrate the
  database stops with a message that names the variable.

  Scenario: The first start on a new database runs every migration
    Given a fresh database
    When the app starts
    Then the start applied every migration
    And the health check reports the latest schema version
    And the database has the tables:
      | accounts            |
      | users               |
      | sessions            |
      | rooms               |
      | memberships         |
      | messages            |
      | boosts              |
      | attachments         |
      | webhooks            |
      | message_search_index  |
      | schema_migrations   |
    And the database is removed

  Scenario: A second start does not run the migrations again
    Given a fresh database
    When the app starts
    And the app restarts
    Then the start applied no migration
    And the health check reports the latest schema version
    And the database is removed

  Scenario: A database that cannot be opened stops the start
    Given the Agentica program "fixtures/server.agc"
    When I send the line "sqlite:/campfire-no-such-directory/campfire.db"
    Then the program exits with code 1 within 5000 milliseconds
    And stderr is:
      """
      campfire: cannot open or migrate the database (CAMPFIRE_DATABASE_URL): sqlite error 14: unable to open database file

      """

Feature: A database that the app cannot use
  A start on a database that is not the schema of the app stops with a message, instead of failing in a request later.

  Scenario: A database made by Rails that lacks a column that the app reads
    Given a fresh database
    And a database made by Rails
    And I run the sql "alter table users drop column status"
    When the app is started and stops
    Then stderr is:
      """
      campfire: cannot open or migrate the database (CAMPFIRE_DATABASE_URL, or CAMPFIRE_DATA_DIR when the url is not set): database error: the database made by Rails has no column users.status

      """

  Scenario: A database of the app from before its history was rewritten to the Rails schema
    Given a fresh database
    And I run the sql "create table schema_migrations (version integer primary key, name text, checksum text)"
    When the app is started and stops
    Then stderr is:
      """
      campfire: cannot open or migrate the database (CAMPFIRE_DATABASE_URL, or CAMPFIRE_DATA_DIR when the url is not set): database error: this database was made by an earlier version of the app, whose migration history was rewritten before the first release: delete the database file and start again

      """

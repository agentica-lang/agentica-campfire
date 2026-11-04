Feature: One pool of database connections
  The app opens a few database connections when it starts and lends one to each request for the length of its work, so a
  burst of requests shares them instead of opening a connection each. (A request that waits too long for a free
  connection is turned away with a 503: test/pool_test.agc holds the only connection to prove it.)

  Background:
    Given a fresh database

  Scenario: Writers that arrive together share three connections and every message is stored
    Given the app starts with 3 database connections that wait 5000 milliseconds
    And the first admin exists
    When I post 12 messages at once to "/rooms/1/messages"
    Then each status is one of "302"
    And the query "select count(*) from messages where room_id = 1 and body like 'burst %'" gives 12

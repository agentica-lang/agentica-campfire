Feature: One pool of database connections
  The app opens a few database connections when it starts and lends one to each request for the length of its work, so a
  burst of requests shares them instead of opening a connection each. A request that waits too long for a free
  connection is turned away with a 503 and a Retry-After, since the server is busy, not broken.

  Background:
    Given a fresh database

  Scenario: Writers that arrive together share two connections and every message is stored
    Given the app starts with 2 database connections that wait 5000 milliseconds
    And the first admin exists
    When I post 12 messages at once to "/rooms/1/messages"
    Then each status is one of "302"
    And the query "select count(*) from messages where room_id = 1 and body like 'burst %'" gives 12

  Scenario: A request that finds every connection busy for too long is answered 503
    Given the app starts with 1 database connections that wait 1 milliseconds
    And the first admin exists
    When I post 16 messages at once to "/rooms/1/messages"
    Then each status is one of "302, 503"
    And at least one status is 503
    And each 503 answer has the header "retry-after" "1"
    When I get "/health"
    Then the status is 200
    When I post to "/rooms/1/messages" the form:
      | body              | after the burst |
      | client_message_id | after-1         |
    Then the status is 302

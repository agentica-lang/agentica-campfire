Feature: A burst of sockets on a small pool
  A page load of many tabs, or the reconnect of a crowd after a restart, opens many sockets of one person at once, and each
  subscribes to the streams of the page. Their checks (the session once, the membership of the room once for a version of
  the database) must not exhaust the three connections of the pool, and the sockets of the person stay open.

  Background:
    Given a fresh database
    And the app starts with 3 database connections that wait 5000 milliseconds
    And the first admin exists
    And the cable peer starts

  Scenario: Forty sockets of one person connect at once and every stream of the room page is confirmed
    When I get "/rooms/1"
    And 40 clients connect at once and subscribe to the streams of the last page
    Then each of the 40 clients is confirmed for every stream of the last page
    When I get "/cable/stats"
    Then the body contains "\"connections\":40"
    And the body contains "\"drops\":0"

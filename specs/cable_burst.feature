Feature: A burst of sockets on a small pool
  A page load of many tabs, or the reconnect of a crowd after a restart, opens many sockets of one person at once, and each
  subscribes to the streams of the page and to the presence of the room. Their checks (the session once, the membership
  of the room once for a version of the database) must not exhaust the three connections of the pool, and the sockets of
  the person stay open. `/cable/stats` counts the reads that the checks made: a first socket warms the checks, and the
  forty after it must read the database next to nothing (the checks read it 41 and 82 times before they were kept).

  Background:
    Given a fresh database
    And the app starts with 3 database connections that wait 5000 milliseconds
    And the first admin exists
    And the cable peer starts

  Scenario: Forty sockets of one person connect at once and every stream of the room page is confirmed
    When I get "/rooms/1"
    And client "warm" connects with the cookies of the browser
    And client "warm" subscribes to the streams of the last page
    And client "warm" subscribes to the channel "PresenceChannel" of the room 1
    Then client "warm" eventually receives a frame containing "confirm_subscription"
    When 40 clients connect at once and subscribe to the streams of the last page
    Then each of the 40 clients is confirmed for every stream of the last page
    When I get "/cable/stats"
    Then the body contains "\"connections\":41"
    And the body contains "\"drops\":0"
    And the cable made at most 3 session reads and 6 membership reads

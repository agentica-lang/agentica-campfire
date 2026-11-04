Feature: What a session row records, and what keeps the table small
  A session row holds the address of the client that signed in. Its `last_active_at` is written at most once every five
  minutes, not on every request. Starting a session removes the rows that no cookie can use any more: those older than
  the cookie life (30 days) and those of a deactivated person. Sign-in is limited to 10 attempts per address in 3
  minutes. The first admin is Ana, user 1, and Bea is user 2.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: A session keeps the address of the client
    Then the query "select count(*) from sessions where user_id = 1 and ip_address = '127.0.0.1'" gives 1

  Scenario: A request marks the session active only when the last mark is five minutes old
    When I run the sql "update sessions set last_active_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 minutes')"
    And I get "/"
    Then the status is 200
    And the query "select count(*) from sessions where last_active_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 seconds')" gives 1
    When I run the sql "update sessions set last_active_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-10 minutes')"
    And I get "/"
    Then the status is 200
    And the query "select count(*) from sessions where last_active_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 seconds')" gives 1

  Scenario: A new session removes the rows past the cookie life and those of a deactivated person
    Given a member "Bea" with the email "bea@example.com" exists
    And I run the sql "insert into sessions (user_id, token, created_at) values (1, 'old', strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-31 days'))"
    And I run the sql "insert into sessions (user_id, token, created_at) values (1, 'recent', strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-29 days'))"
    And I run the sql "update users set active = 0 where id = 2"
    And I run the sql "insert into sessions (user_id, token) values (2, 'gone')"
    When I sign in as "ana@example.com"
    Then the query "select count(*) from sessions where token in ('old', 'gone')" gives 0
    And the query "select count(*) from sessions where token = 'recent'" gives 1
    And the query "select count(*) from sessions" gives 3

  Scenario: The 11th sign-in attempt from one address in the window is refused with a 429
    Given the browser has no cookies
    When I post to "/session" 12 times at once the form:
      | email_address | nobody@example.com |
    Then exactly 2 statuses are 429
    When I post to "/session" the form:
      | email_address | ana@example.com       |
      | password      | correct horse battery |
    Then the status is 429
    And the header "retry-after" is a whole number from 1 to 180
    And the body contains "Too many sign-in attempts"
    And the query "select count(*) from sessions" gives 1

  Scenario: Another path to the same route does not escape the limit
    When I post to "/session/" 12 times at once the form:
      | email | nobody@example.com |
    Then exactly 2 statuses are 429
    When I post to "/session" the form:
      | email_address | nobody@example.com |
    Then the status is 429

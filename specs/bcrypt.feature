Feature: Digests from a Rails Campfire
  Upstream Campfire is a Rails app, which stores passwords as bcrypt digests (`$2a$12$...`). The app checks those
  next to its own scrypt ones, through the libcrypt of the system, so a database that came from Rails signs in as it is.
  New passwords are always scrypt, and the digest of a person who signs in is not rewritten.

  Background:
    Given bcrypt digests can be checked on this system
    And a fresh database
    And the app starts
    And the first admin exists
    And the browser has no cookies

  Scenario: A person with a bcrypt digest of cost 12 signs in with the right password
    Given a member "Dave" with the email "dave@example.com" and the password digest "$2a$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6KQoUDvUdMi" exists
    When I post to "/session" the form:
      | email_address | dave@example.com      |
      | password      | correct horse battery |
    Then the status is 302
    And the header "location" is "/"
    And the header "set-cookie" contains "session_token="
    When I get "/users/me/sidebar"
    Then the status is 200
    And the body contains "Signed in as Dave"
    And the query "select count(*) from users where password_digest like '$2a$12$%'" gives 1
    And the query "select count(*) from users where password_digest like 'scrypt$%'" gives 1

  Scenario Outline: Every version of bcrypt that Rails and other apps write is checked
    Given a member "Dave" with the email "dave@example.com" and the password digest "<digest>" exists
    When I post to "/session" the form:
      | email_address | dave@example.com |
      | password      | <password>       |
    Then the status is 302
    And the header "location" is "/"

    Examples:
      | digest                                                        | password              |
      | $2b$04$UG3YtrQhF1zPxFoJD1xZMekAw7n4Krqhj2PoZGIRLnUtMhBtsNeIq | secret-password       |
      | $2y$04$CXxbbFo6fuFlmT39vHoMJOx5CHCN0f7Htpbomo0UnoVwHw.N5iaU. | secret-password       |
      | $2y$12$1jFHU53lJapRtuGG/Se1qO0ZjSPSvBewzTvJ0T4DbNo1jZJv.mTm. | correct horse battery |

  Scenario Outline: A wrong password, or a digest that is damaged, does not sign in and is answered like any wrong login
    Given a member "Dave" with the email "dave@example.com" and the password digest "<digest>" exists
    When I post to "/session" the form:
      | email_address | dave@example.com |
      | password      | <password>       |
    Then the status is 422
    And the body contains "Wrong email or password"
    And the query "select count(*) from sessions" gives 1

    Examples:
      | digest                                                        | password              |
      | $2a$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6KQoUDvUdMi | correct horse batterz |
      | $2a$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6KQoUDvUdMi | secret-password       |
      | $2a$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6KQoUDvUdMi | Correct horse battery |
      | $2a$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6KQoUDvUdMi |                       |
      | $2a$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6                | correct horse battery |
      | $2x$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6KQoUDvUdMi | correct horse battery |

  Scenario: Sign-ins that check a bcrypt digest share the hashing slots and the app keeps serving
    Given a member "Dave" with the email "dave@example.com" and the password digest "$2a$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6KQoUDvUdMi" exists
    When I post to "/session" 8 times at once the form:
      | email_address | dave@example.com |
      | password      | not the password |
    Then each status is one of "422, 503"
    And at least one status is 422
    And each 503 answer has the header "retry-after" "1"
    When I get "/health"
    Then the status is 200
    When I post to "/session" the form:
      | email_address | dave@example.com      |
      | password      | correct horse battery |
    Then the status is 302

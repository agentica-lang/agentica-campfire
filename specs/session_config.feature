Feature: The session secret and the cookie
  The session cookie is signed with CAMPFIRE_SESSION_SECRET, which the app needs (at least 32 bytes) and never has a
  default for. Behind HTTPS, CAMPFIRE_SECURE_COOKIES=true makes the cookie `Secure` with the `__Host-` prefix, which a
  browser only takes from the host itself.

  Scenario: Behind HTTPS the cookie is Secure and has the __Host- prefix
    Given a fresh database
    And the app starts with secure cookies
    When I post to "/first_run" the form:
      | name     | Ana                   |
      | email    | ana@example.com       |
      | password | correct horse battery |
    Then the status is 302
    And the header "set-cookie" contains "__Host-session_token="
    And the header "set-cookie" contains "Secure"

  Scenario: Behind HTTPS the cookie of the last room is Secure too
    Given a fresh database
    And the app starts with secure cookies
    And the first admin exists
    When I get "/rooms/1"
    Then the status is 200
    And the header "set-cookie" contains "last_room=1; Path=/; Max-Age=630720000; Secure; HttpOnly"

  Scenario Outline: A start without a usable session secret stops
    Given the environment variable "CAMPFIRE_HOST" is "127.0.0.1"
    And the environment variable "CAMPFIRE_PORT" is "0"
    And the environment variable "CAMPFIRE_DATA_DIR" is "unused"
    And the environment variable "CAMPFIRE_SESSION_SECRET" is "<secret>"
    And the Agentica program "fixtures/server.agc"
    Then the program exits with code 1 within 30000 milliseconds
    And stderr is:
      """
      campfire: CAMPFIRE_SESSION_SECRET must have at least 32 bytes (make one with: openssl rand -hex 32)

      """

    Examples:
      | secret    |
      |           |
      | too short |

  Scenario: A start with a value that is not true or false for the secure cookies stops
    Given the environment variable "CAMPFIRE_HOST" is "127.0.0.1"
    And the environment variable "CAMPFIRE_PORT" is "0"
    And the environment variable "CAMPFIRE_DATA_DIR" is "unused"
    And the environment variable "CAMPFIRE_SESSION_SECRET" is "0123456789abcdef0123456789abcdef"
    And the environment variable "CAMPFIRE_SECURE_COOKIES" is "yes"
    And the Agentica program "fixtures/server.agc"
    Then the program exits with code 1 within 30000 milliseconds
    And stderr is:
      """
      campfire: CAMPFIRE_SECURE_COOKIES must be true or false, not "yes"

      """

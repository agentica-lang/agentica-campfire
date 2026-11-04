Feature: The library that checks bcrypt digests
  bcrypt digests are checked by `crypt_r` of a library: `libcrypt.so.1` on Linux, or the one that
  CAMPFIRE_BCRYPT_LIBRARY names (macOS and Windows have none of their own). A library that cannot be used does not
  stop the app: only the sign-in of a person with a bcrypt digest fails, with an error of the app and not as a wrong
  password. People with scrypt digests are not affected.

  Scenario: A library that is not there fails the sign-in of a bcrypt account and nobody else's
    Given a fresh database
    And the bcrypt library is "/nonexistent/libcrypt.so"
    And the app starts
    And the first admin exists
    And a member "Dave" with the email "dave@example.com" and the password digest "$2a$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6KQoUDvUdMi" exists
    When I post to "/session" the form:
      | email_address | dave@example.com      |
      | password      | correct horse battery |
    Then the status is 500
    And the body does not contain "libcrypt"
    And the query "select count(*) from sessions" gives 1
    When I post to "/session" the form:
      | email_address | dave@example.com |
      | password      | not the password |
    Then the status is 500
    When I get "/health"
    Then the status is 200
    When I sign in as "ana@example.com"
    Then the status is 302
    And the query "select count(*) from sessions" gives 2

  Scenario: The default library of Linux can be named
    Given this system is Linux
    And a fresh database
    And the bcrypt library is "libcrypt.so.1"
    And the app starts
    And the first admin exists
    And a member "Dave" with the email "dave@example.com" and the password digest "$2y$12$1jFHU53lJapRtuGG/Se1qO0ZjSPSvBewzTvJ0T4DbNo1jZJv.mTm." exists
    When I post to "/session" the form:
      | email_address | dave@example.com      |
      | password      | correct horse battery |
    Then the status is 302

Feature: Password reset
  "Forgot password" on the sign-in page takes an email. The answer is the same whether or not an account has that
  email, so the form cannot be used to find out who is registered. For an account, the app emails a link with a random
  token, of which only a hash is kept, that works once and for 30 minutes. The page of the link sets a new password
  with the rules of the first run, ends every session that the person had, and signs them in. The mail goes through a
  mail server that the specs run (the SMTP peer), and the specs follow the link that it received.

  Background:
    Given a fresh database
    And the mail server is listening
    And the app sends its email through the mail server
    And the app starts
    And the first admin exists
    And the browser saves a copy of its cookies
    And the browser has no cookies

  Scenario: The sign-in page offers the form, which asks for an email only
    When I get "/session/new"
    Then the status is 200
    And the body contains "<a href=\"/password_reset/new\">"
    When I get "/password_reset/new"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/password_reset\">"
    And the body contains "name=\"email\" type=\"email\""
    And the body does not contain "type=\"password\""

  Scenario: The link in the email sets a new password, signs the person in and ends the other sessions
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the status is 200
    And the body contains "If an account has that email"
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    When I open the link of the email
    Then the status is 200
    And the header "referrer-policy" is "no-referrer"
    And the header "cache-control" is "no-store"
    And the body contains "name=\"password\" type=\"password\""
    When I set the password "a brand new password" with the token of the link
    Then the status is 302
    And the header "location" is "/"
    And the header "set-cookie" contains "_campfire_session="
    When I get "/"
    Then the status is 200
    And the body contains "Signed in as Ana"
    And the query "select count(*) from sessions" gives 1
    And the query "select count(*) from password_resets where used_at is null" gives 0
    When the browser restores its saved cookies
    And I get "/"
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: The new password works at sign-in and the old one does not
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    And I open the link of the email
    And I set the password "a brand new password" with the token of the link
    And the browser has no cookies
    And I post to "/session" the form:
      | email    | ana@example.com       |
      | password | correct horse battery |
    Then the status is 422
    When I post to "/session" the form:
      | email    | ana@example.com      |
      | password | a brand new password |
    Then the status is 302
    And the header "location" is "/"

  Scenario: An email that no account has gets the answer that an account gets, and no email
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And I remember the answer
    And I post to "/password_reset" the form:
      | email | nobody@example.com |
    Then the answer is the one that I remembered
    And the query "select count(*) from password_resets" gives 1

  Scenario: An email that no account has makes no token and sends nothing
    When I post to "/password_reset" the form:
      | email | nobody@example.com |
    Then the status is 200
    And the query "select count(*) from password_resets" gives 0
    And the mail server received nothing within 700 milliseconds

  Scenario: Only a hash of the token is kept
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    And I open the link of the email
    Then the database does not hold the token of the link
    And the query "select count(*) from password_resets where length(token_digest) = 64" gives 1

  Scenario: A token works once
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    And I open the link of the email
    And I set the password "the first new password" with the token of the link
    Then the status is 302
    When the browser has no cookies
    And I set the password "a second new password" with the token of the link
    Then the status is 410
    And the header "cache-control" is "no-store"
    And the header "referrer-policy" is "no-referrer"
    When I open the link of the email
    Then the status is 410
    When I post to "/session" the form:
      | email    | ana@example.com        |
      | password | the first new password |
    Then the status is 302

  Scenario: A token expires
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    And I open the link of the email
    Then the status is 200
    When I run the sql "update password_resets set expires_at = '2000-01-01T00:00:00.000Z'"
    And I open the link of the email
    Then the status is 410
    When I set the password "a brand new password" with the token of the link
    Then the status is 410
    And the query "select count(*) from sessions" gives 1

  Scenario: A token lasts about 30 minutes
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the query "select count(*) from password_resets where expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+29 minutes') and expires_at <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+30 minutes')" gives 1

  Scenario Outline: A new password that breaks the rules is refused and the link stays good
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    And I open the link of the email
    And I set the password "<password>" with the token of the link
    Then the status is 422
    And the header "cache-control" is "no-store"
    And the header "referrer-policy" is "no-referrer"
    And the body contains "<message>"
    And the body does not contain "<password>"
    And the query "select count(*) from password_resets" gives 1
    When I set the password "a brand new password" with the token of the link
    Then the status is 302

    Examples:
      | password | message                                  |
      | short    | The password needs at least 8 characters |

  Scenario Outline: A token that is not one gets the page of a link that does not work
    When I get "/password_reset/edit?token=<token>"
    Then the status is 410
    And the body does not contain "alert(1)"
    When I set the password "a brand new password" with the token "<token>"
    Then the status is 410

    Examples:
      | token                     |
      | nothing                   |
      |                           |
      | <script>alert(1)</script> |

  Scenario: The link starts with the address that the app is given, whatever host the request names
    # The client of the specs cannot change `Host`, so the request names the host the way a proxy does.
    Given the request header "X-Forwarded-Host" is "evil.test"
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the status is 200
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    When I open the link of the email
    Then the body contains "name=\"password\" type=\"password\""

  Scenario: A new request while the link is live sends nothing and leaves the link good
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    And I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the status is 200
    And the query "select count(*) from password_resets" gives 1
    When I open the link of the email
    And I set the password "a brand new password" with the token of the link
    Then the status is 302

  Scenario: After a link is used a new request waits five minutes, and then makes a new link
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    And I open the link of the email
    And I set the password "a brand new password" with the token of the link
    And the browser has no cookies
    And I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the query "select count(*) from password_resets where used_at is null" gives 0
    When I run the sql "update password_resets set created_at = '2000-01-01T00:00:00.000Z'"
    And I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the query "select count(*) from password_resets where used_at is null" gives 1

  Scenario: Parallel requests for one email make one link and send one email
    When I post to "/password_reset" 8 times at once the form:
      | email | ana@example.com |
    Then the query "select count(*) from password_resets" gives 1
    When I close stdin
    Then the program exits with code 0 within 10000 milliseconds
    And stderr is:
      """
      """

  Scenario: Two forms with one link change the password once
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    And I open the link of the email
    And I set the password "a brand new password" with the token of the link 2 times at once
    Then exactly 1 statuses are 302
    And exactly 1 statuses are 410
    And the query "select count(*) from sessions" gives 1

  Scenario: Forms that arrive while the hash slots are busy are answered 503 with the form again
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And the mail server received a message to "ana@example.com" with the subject "Reset your Campfire password"
    And I open the link of the email
    And I set the password "a brand new password" with the token of the link 10 times at once
    Then each status is one of "302, 410, 503"
    And exactly 1 statuses are 302
    And at least one status is 503
    And each 503 answer has the header "retry-after" "1"
    And each 503 answer has a body that contains "The server is busy"
    And each 503 answer has a body that contains "name=\"password\" type=\"password\""

  Scenario: A person who is deactivated gets no link
    Given I run the sql "update users set active = 0"
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the status is 200
    And the query "select count(*) from password_resets" gives 0

  Scenario: The email is found whatever its case
    When I post to "/password_reset" the form:
      | email | ANA@Example.com |
    Then the query "select count(*) from password_resets" gives 1

  Scenario Outline: A form from another site is refused
    Given the request header "Sec-Fetch-Site" is "cross-site"
    When I post to "<path>" the form:
      | email    | ana@example.com |
      | token    | whatever        |
      | password | a new password  |
    Then the status is 403
    And the query "select count(*) from password_resets" gives 0

    Examples:
      | path                     |
      | /password_reset          |
      | /password_reset/confirm  |

Feature: First run, sign in and sign out
  A new app has no account. Every page except the health check and the first-run and sign-in pages needs a
  signed-in user, so a visitor is sent to the first-run page while there is no account, and to the sign-in page after
  that. The first-run form makes the account and its administrator, and signs that person in. After that people sign in
  with an email and a password, and sign out. The session is a signed cookie that holds a token, and the token is
  checked against the `sessions` table, so signing out ends the session on the server too.

  Background:
    Given a fresh database
    And the app starts

  Scenario: A new app sends every visitor to the first-run page
    When I get "/"
    Then the status is 302
    And the header "location" is "/first_run"
    When I get "/session/new"
    Then the status is 302
    And the header "location" is "/first_run"

  Scenario: The first-run page is a form
    When I get "/first_run"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/first_run\">"
    And the body contains "name=\"password\" type=\"password\""

  Scenario: The first run makes the administrator and signs them in
    When I post to "/first_run" the form:
      | name     | Ana                  |
      | email    | ana@example.com      |
      | password | correct horse battery |
    Then the status is 302
    And the header "location" is "/"
    And the header "set-cookie" contains "HttpOnly"
    And the header "set-cookie" contains "SameSite=Lax"
    And the header "set-cookie" contains "session_token="
    And the header "set-cookie" does not contain "Secure"
    And the header "set-cookie" does not contain "__Host-"
    When I get "/users/me/sidebar"
    Then the status is 200
    And the body contains "Signed in as Ana"
    And the query "select count(*) from accounts" gives 1
    And the query "select count(*) from users where role = 1 and email_address = 'ana@example.com'" gives 1
    And the query "select count(*) from sessions" gives 1

  # Through the form, as every scenario that posts it: `the first admin exists` writes a cheaper digest of its own.
  Scenario: The password is stored as a slow hash, never as text
    When I post to "/first_run" the form:
      | name     | Ana                   |
      | email    | ana@example.com       |
      | password | correct horse battery |
    Then the status is 302
    And the query "select count(*) from users where password_digest like 'scrypt$65536$8$2$%'" gives 1
    And the query "select count(*) from users where password_digest like '%correct horse%'" gives 0

  Scenario Outline: A first-run form with a bad value makes no account
    When I post to "/first_run" the form:
      | name     | <name>     |
      | email    | <email>    |
      | password | <password> |
    Then the status is 422
    And the body contains "<message>"
    And the query "select count(*) from users" gives 0
    And the query "select count(*) from accounts" gives 0

    Examples:
      | name | email           | password              | message                                 |
      |      | ana@example.com | correct horse battery | Enter your name                         |
      | Ana  | not-an-email    | correct horse battery | Enter a valid email address             |
      | Ana  | ana@example.com | short                 | The password needs at least 8 characters |

  Scenario: The values of the client are escaped when the form is shown again
    When I post to "/first_run" the form:
      | name     | <script>alert(1)</script> |
      | email    | nope                      |
      | password | correct horse battery     |
    Then the status is 422
    And the body contains "value=\"&lt;script&gt;alert(1)&lt;/script&gt;\""
    And the body does not contain "<script>alert(1)</script>"

  Scenario: A quote in a value cannot leave its attribute when the form is shown again
    When I post to "/first_run" the form:
      | name     | " onfocus='alert(1)' x="  |
      | email    | nope                      |
      | password | correct horse battery     |
    Then the status is 422
    And the body contains "value=\"&quot; onfocus=&#39;alert(1)&#39; x=&quot;\""

  Scenario: A closed app answers a bad first-run form with a redirect, before any hashing
    Given the first admin exists
    And the browser has no cookies
    When I post to "/first_run" the form:
      | name     |       |
      | email    | nope  |
      | password | short |
    Then the status is 302
    And the header "location" is "/"

  Scenario: A closed app never answers a first-run form with a 503
    Given the first admin exists
    And the browser has no cookies
    When I post to "/first_run" 8 times at once the form:
      | name     | Eve                   |
      | email    | eve@example.com       |
      | password | another long password |
    Then each status is one of "302"
    And the query "select count(*) from users" gives 1

  Scenario: Forms that arrive together make one account and one user
    When I post to "/first_run" 4 times at once the form:
      | name     | Ana                   |
      | email    | ana@example.com       |
      | password | correct horse battery |
    Then each status is one of "302, 503"
    And at least one status is 302
    And each 503 answer has the header "retry-after" "1"
    And the query "select count(*) from accounts" gives 1
    And the query "select count(*) from users" gives 1
    And the query "select count(*) from sessions" gives 1

  Scenario: The first run happens once
    Given the first admin exists
    And the browser has no cookies
    When I get "/first_run"
    Then the status is 302
    And the header "location" is "/"
    When I post to "/first_run" the form:
      | name     | Eve                    |
      | email    | eve@example.com        |
      | password | another long password  |
    Then the status is 302
    And the header "location" is "/"
    And the query "select count(*) from users" gives 1

  Scenario: After the first run a visitor is sent to the sign-in page
    Given the first admin exists
    And the browser has no cookies
    When I get "/"
    Then the status is 302
    And the header "location" is "/session/new"
    When I get "/session/new"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/session\">"
    And the body contains "name=\"email_address\" type=\"email\""

  Scenario: A page that has no route needs a sign-in too, so the filter is the rule and not a list of pages
    Given the first admin exists
    And the browser has no cookies
    When I get "/nothing"
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: A password with symbols and spaces survives the form
    When I post to "/first_run" the form:
      | name     | Ana             |
      | email    | ana@example.com |
      | password | p&ss w0rd=+%25  |
    And the browser has no cookies
    And I post to "/session" the form:
      | email_address | ana@example.com |
      | password      | p&ss w0rd=+%25  |
    Then the status is 302
    And the header "location" is "/"

  Scenario: Signing in with an email and a password
    Given the first admin exists
    And the browser has no cookies
    When I post to "/session" the form:
      | email_address | ANA@example.com       |
      | password      | correct horse battery |
    Then the status is 302
    And the header "location" is "/"
    When I get "/users/me/sidebar"
    Then the status is 200
    And the body contains "Signed in as Ana"
    And the query "select count(*) from sessions" gives 2

  Scenario Outline: A wrong email or password does not sign in, and does not say which was wrong
    Given the first admin exists
    And the browser has no cookies
    When I post to "/session" the form:
      | email_address | <email>    |
      | password      | <password> |
    Then the status is 422
    And the body contains "Wrong email or password"
    And the query "select count(*) from sessions" gives 1
    When I get "/"
    Then the status is 302
    And the header "location" is "/session/new"

    Examples:
      | email           | password              |
      | ana@example.com | not the password      |
      | bea@example.com | correct horse battery |

  Scenario: A bot cannot sign in
    Given the first admin exists
    And the browser has no cookies
    And a bot "Hook" with the token "tok" exists
    When I post to "/session" the form:
      | email_address |     |
      | password      | tok |
    Then the status is 422
    And the body contains "Wrong email or password"
    And the query "select count(*) from sessions" gives 1

  Scenario Outline: A value that is too long is refused like an unknown email, without hashing it
    Given the first admin exists
    And the browser has no cookies
    When I post to "/session" the form:
      | email_address | <email>    |
      | password      | <password> |
    Then the status is 422
    And the body contains "Wrong email or password"

    Examples:
      | email                | password                                                                                                                                                                                                                                                                         |
      | ana@example.com      | pppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp |
      | eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee@example.com | correct horse battery |

  Scenario: Many sign-ins at once are answered, or turned away with a 503, and the app keeps serving
    Given the first admin exists
    And the browser has no cookies
    When I post to "/session" 8 times at once the form:
      | email_address | ana@example.com  |
      | password      | not the password |
    Then each status is one of "422, 503"
    And at least one status is 422
    And each 503 answer has the header "retry-after" "1"
    When I get "/health"
    Then the status is 200
    When I post to "/session" the form:
      | email_address | ana@example.com       |
      | password      | correct horse battery |
    Then the status is 302
    And the header "location" is "/"

  # What the benchmark harness of upstream Campfire sends: a browser's `Sec-Fetch-Site`, no `Origin` and no token.
  Scenario: A sign-in that says it comes from the same origin works, and sets the cookie of Rails
    Given the first admin exists
    And the browser has no cookies
    And the request header "sec-fetch-site" is "same-origin"
    When I post to "/session" the form:
      | email_address | ana@example.com       |
      | password      | correct horse battery |
    Then the status is 302
    And the header "location" is "/"
    And the header "set-cookie" contains "session_token="
    And the header "set-cookie" does not contain "_campfire_session"
    When I get "/users/me/sidebar"
    Then the status is 200
    And the body contains "Signed in as Ana"

  Scenario Outline: A sign-in is allowed from the same origin and refused from another subdomain or site
    Given the first admin exists
    And the browser has no cookies
    And the request header "sec-fetch-site" is "<site>"
    When I post to "/session" the form:
      | email_address | ana@example.com       |
      | password      | correct horse battery |
    Then the status is <status>

    Examples:
      | site        | status |
      | same-origin | 302    |
      | none        | 302    |
      | same-site   | 403    |
      | cross-site  | 403    |

  Scenario: A user that was deactivated loses the session and cannot sign in
    Given the first admin exists
    And I run the sql "update users set status = 1"
    When I get "/"
    Then the status is 302
    And the header "location" is "/session/new"
    When I post to "/session" the form:
      | email_address | ana@example.com       |
      | password      | correct horse battery |
    Then the status is 422

  Scenario: Signing out ends the session on the server
    Given the first admin exists
    And the browser saves a copy of its cookies
    When I post nothing to "/sign_out"
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from sessions" gives 0
    When I get "/"
    Then the status is 302
    And the header "location" is "/session/new"
    When the browser restores its saved cookies
    And I get "/"
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: A sign-out that cannot reach the session still drops the cookie, and says it failed
    Given the first admin exists
    And I run the sql "create trigger keep_sessions before delete on sessions begin select raise(abort, 'kept'); end"
    When I post nothing to "/sign_out"
    Then the status is 500
    And the header "set-cookie" contains "Max-Age=0"
    When I get "/"
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: A cookie that was not signed by the app is an empty session
    Given the first admin exists
    And the browser has the cookie "session_token" with the value "abc.def"
    When I get "/"
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: A page of another site cannot post a form
    When the request header "sec-fetch-site" is "cross-site"
    And I post to "/first_run" the form:
      | name     | Ana                   |
      | email    | ana@example.com       |
      | password | correct horse battery |
    Then the status is 403
    And the query "select count(*) from users" gives 0

  Scenario Outline: A page of another site cannot sign in or sign out for the visitor
    Given the first admin exists
    And the request header "sec-fetch-site" is "cross-site"
    When I post to "<path>" the form:
      | email_address | ana@example.com       |
      | password      | correct horse battery |
    Then the status is 403
    And the query "select count(*) from sessions" gives 1

    Examples:
      | path      |
      | /session  |
      | /sign_out |

  Scenario: A signed-in visitor does not see the sign-in page
    Given the first admin exists
    When I get "/session/new"
    Then the status is 302
    And the header "location" is "/"

  Scenario: The health check needs no sign-in
    Given the first admin exists
    And the browser has no cookies
    When I get "/health"
    Then the status is 200

  Scenario: The page that the benchmark harness of Rails Campfire checks needs no sign-in
    Given the first admin exists
    And the browser has no cookies
    When I get "/up"
    Then the status is 200
    And the body contains "background-color: green"

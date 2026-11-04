Feature: Joining with the link
  An account has a join code, and `/join/CODE` lets a new person sign up with a name, an email and a password. It is the
  only page besides the sign-in ones that needs no session, and a code that is not the account's, an old one included,
  answers 404 like any page that is not there. The person joins every open room that exists and is signed in. The first
  admin is Ana, user 1, and "All Talk" is room 1. The specs set the code to `aaaa-bbbb-cccc`.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And I run the sql "update accounts set join_code = 'aaaa-bbbb-cccc'"

  Scenario: The page of the link is a form and needs no sign-in
    Given the browser has no cookies
    When I get "/join/aaaa-bbbb-cccc"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/join/aaaa-bbbb-cccc\">"
    And the body contains "name=\"name\""
    And the body contains "name=\"email\" type=\"email\""
    And the body contains "name=\"password\" type=\"password\""
    And the header "cache-control" is "no-store"
    And the header "referrer-policy" is "no-referrer"

  Scenario: A person who joins is in every open room, none of the closed ones, and is signed in
    Given I post to "/rooms" the form:
      | name | Lunch |
    And I post to "/closed_rooms" the form:
      | name | Secret |
    And the browser has no cookies
    When I get "/join/aaaa-bbbb-cccc"
    And I submit the join form of the page with:
      | name     | Bea                   |
      | email    | Bea@Example.com       |
      | password | another long password |
    Then the status is 302
    And the header "location" is "/"
    And the header "set-cookie" contains "_campfire_session="
    When I get "/"
    Then the status is 200
    And the body contains "Signed in as Bea"
    And the body contains "<a href=\"/rooms/1\">All Talk</a>"
    And the body contains "<a href=\"/rooms/2\">Lunch</a>"
    And the body does not contain "Secret"
    And the query "select count(*) from users where (id, name, email, role, active) = (2, 'Bea', 'bea@example.com', 'member', 1)" gives 1
    And the query "select count(*) from users where id = 2 and password_digest like 'scrypt$%'" gives 1
    And the query "select count(*) from memberships where user_id = 2 and room_id in (1, 2)" gives 2
    And the query "select count(*) from memberships where user_id = 2" gives 2
    And the query "select count(*) from sessions where user_id = 2" gives 1

  Scenario: The new person can sign in again with the password they chose
    Given the browser has no cookies
    When I post to "/join/aaaa-bbbb-cccc" the form:
      | name     | Bea                   |
      | email    | bea@example.com       |
      | password | another long password |
    And I sign in as "bea@example.com"
    And I get "/"
    Then the body contains "Signed in as Bea"

  Scenario Outline: A code that is not the account's is a 404 like any missing page, for a page and for a form
    Given the browser has no cookies
    When I get "/join/<code>"
    Then the status is 404
    And the body is "Not Found"
    When I post to "/join/<code>" the form:
      | name     | Bea                   |
      | email    | bea@example.com       |
      | password | another long password |
    Then the status is 404
    And the body is "Not Found"
    And the query "select count(*) from users" gives 1
    And the query "select count(*) from sessions" gives 1

    Examples:
      | code                                                                                                                                        |
      | wrong                                                                                                                                       |
      | AAAA-BBBB-CCCC                                                                                                                              |
      | aaaa-bbbb                                                                                                                                   |
      | aaaa-bbbb-cccc-dddd                                                                                                                         |
      | aaaaaaaa-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb |

  Scenario: A wrong code answers what a missing page answers
    When I get "/join/zzzz-zzzz-zzzz"
    And I remember the answer
    And I get "/nothing"
    Then the answer is the one that I remembered

  Scenario Outline: A form with a bad value makes nobody, and the form comes back without the password
    Given the browser has no cookies
    When I post to "/join/aaaa-bbbb-cccc" the form:
      | name     | <name>     |
      | email    | <email>    |
      | password | <password> |
    Then the status is 422
    And the body contains "<message>"
    And the body contains "action=\"/join/aaaa-bbbb-cccc\""
    And the body does not contain "<password>"
    And the query "select count(*) from users" gives 1

    Examples:
      | name | email           | password              | message                                  |
      |      | bea@example.com | another long password | Enter your name                          |
      | Bea  | not-an-email    | another long password | Enter a valid email address              |
      | Bea  | bea@example.com | short                 | The password needs at least 8 characters |

  Scenario: The values of the client are escaped when the form comes back
    Given the browser has no cookies
    When I post to "/join/aaaa-bbbb-cccc" the form:
      | name     | <script>alert(1)</script> |
      | email    | nope                      |
      | password | another long password     |
    Then the status is 422
    And the body contains "value=\"&lt;script&gt;alert(1)&lt;/script&gt;\""
    And the body does not contain "<script>alert(1)</script>"

  Scenario: An email that has an account, whatever its case, is refused, and so is one of a deactivated person
    Given a member "Bea" with the email "bea@example.com" exists
    And I run the sql "insert into users (name, email, password_digest, active) values ('Cy', 'cy@example.com', 'x', 0)"
    And the browser has no cookies
    When I post to "/join/aaaa-bbbb-cccc" the form:
      | name     | Bea Two               |
      | email    | BEA@example.com       |
      | password | another long password |
    Then the status is 422
    And the body contains "An account with that email exists already"
    When I post to "/join/aaaa-bbbb-cccc" the form:
      | name     | Cy Two                |
      | email    | cy@example.com        |
      | password | another long password |
    Then the status is 422
    And the query "select count(*) from users" gives 3
    And the query "select count(*) from users where active = 0" gives 1

  Scenario: Forms for one email that arrive together make one person
    Given the browser has no cookies
    When I post to "/join/aaaa-bbbb-cccc" 8 times at once the form:
      | name     | Bea                   |
      | email    | bea@example.com       |
      | password | another long password |
    Then each status is one of "302, 422, 503"
    And exactly 1 statuses are 302
    And each 503 answer has the header "retry-after" "1"
    And the query "select count(*) from users where email = 'bea@example.com'" gives 1
    And the query "select count(*) from memberships where user_id = 2" gives 1
    And the query "select count(*) from sessions where user_id = 2" gives 1
    When I get "/health"
    Then the status is 200

  Scenario: A code that is regenerated while the form is open refuses the form
    Given the browser has no cookies
    When I get "/join/aaaa-bbbb-cccc"
    And I run the sql "update accounts set join_code = 'dddd-eeee-ffff'"
    And I submit the join form of the page with:
      | name     | Bea                   |
      | email    | bea@example.com       |
      | password | another long password |
    Then the status is 404
    And the query "select count(*) from users" gives 1

  Scenario: A page of another site cannot sign anybody up
    Given the browser has no cookies
    And the request header "sec-fetch-site" is "cross-site"
    When I post to "/join/aaaa-bbbb-cccc" the form:
      | name     | Bea                   |
      | email    | bea@example.com       |
      | password | another long password |
    Then the status is 403
    And the query "select count(*) from users" gives 1

  Scenario: Only the join page is open: other pages under it still need a sign-in
    Given the browser has no cookies
    When I get "/join/aaaa-bbbb-cccc/more"
    Then the status is 302
    And the header "location" is "/session/new"
    When I get "/join"
    Then the status is 302
    And the header "location" is "/session/new"

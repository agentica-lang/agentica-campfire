Feature: The people of the account
  Everybody who is signed in sees who is on the account. An administrator also sees their emails, and can deactivate a
  person, which ends their sessions and stops them signing in, and reactivate them, which puts them in the open rooms
  that were made while they were away. The first admin is Ana, user 1, "All Talk" is room 1, Bea is user 2 and Cy is
  user 3.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And I run the sql "update accounts set join_code = 'aaaa-bbbb-cccc'"

  Scenario: A member sees the people and nothing that only an administrator needs
    Given I sign in as "bea@example.com"
    When I get "/"
    Then the body contains "<a href=\"/users\">People</a>"
    When I get "/users"
    Then the status is 200
    And the body contains "Ana"
    And the body contains "Bea"
    And the body contains "Cy"
    And the body does not contain "example.com"
    And the body does not contain "/join/"
    And the body does not contain "aaaa-bbbb-cccc"
    And the body does not contain "action=\"/users/"
    And the body does not contain "action=\"/account/"

  Scenario: An administrator sees the emails, the join link, and a button for everybody but themselves
    When I get "/users"
    Then the status is 200
    And the body contains "ana@example.com"
    And the body contains "bea@example.com"
    And the body contains "/join/aaaa-bbbb-cccc"
    And the body contains "action=\"/users/2/deactivate\""
    And the body contains "action=\"/users/3/deactivate\""
    And the body does not contain "action=\"/users/1/deactivate\""

  Scenario: Deactivating a person ends their sessions and keeps them out
    Given I sign in as "bea@example.com"
    And the browser saves a copy of its cookies
    And I run the sql "insert into password_resets (user_id, token_digest, expires_at) values (2, 'abc', strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+30 minutes'))"
    And I sign in as "ana@example.com"
    When I get "/users"
    And I submit the form of the page that posts to "/users/2/deactivate"
    Then the status is 302
    And the header "location" is "/users"
    And the query "select count(*) from users where id = 2 and active = 0" gives 1
    And the query "select count(*) from sessions where user_id = 2" gives 0
    And the query "select count(*) from password_resets where user_id = 2" gives 0
    When the browser restores its saved cookies
    And I get "/"
    Then the status is 302
    And the header "location" is "/session/new"
    When I post to "/session" the form:
      | email_address | bea@example.com       |
      | password      | another long password |
    Then the status is 422
    And the body contains "Wrong email or password"
    When I sign in as "cy@example.com"
    And I get "/users"
    Then the body does not contain "Bea"
    When I get "/closed_rooms/new"
    Then the body does not contain "Bea"

  Scenario: An administrator still sees a deactivated person, and can reactivate them
    Given I run the sql "update users set active = 0 where id = 2"
    When I get "/users"
    Then the body contains "bea@example.com"
    And the body contains "action=\"/users/2/reactivate\""
    And the body does not contain "action=\"/users/2/deactivate\""
    When I submit the form of the page that posts to "/users/2/reactivate"
    Then the status is 302
    And the header "location" is "/users"
    And the query "select count(*) from users where id = 2 and active = 1" gives 1
    When I sign in as "bea@example.com"
    Then the status is 302

  Scenario: A reactivated person is put in the open rooms made while they were away
    Given I get "/users"
    And I submit the form of the page that posts to "/users/2/deactivate"
    And I post to "/rooms" the form:
      | name | Lunch |
    And the query "select count(*) from memberships where room_id = 2 and user_id = 2" gives 0
    When I get "/users"
    And I submit the form of the page that posts to "/users/2/reactivate"
    Then the query "select count(*) from memberships where room_id in (1, 2) and user_id = 2" gives 2
    When I sign in as "bea@example.com"
    And I get "/"
    Then the body contains "<a href=\"/rooms/2\">Lunch</a>"

  Scenario: Deactivating and reactivating again and again changes nothing more
    Given I get "/users"
    When I post nothing to "/users/2/deactivate"
    And I post nothing to "/users/2/deactivate"
    Then the status is 302
    And the query "select count(*) from users where id = 2 and active = 0" gives 1
    When I post nothing to "/users/2/reactivate"
    And I post nothing to "/users/2/reactivate"
    Then the status is 302
    And the query "select count(*) from users where id = 2 and active = 1" gives 1
    And the query "select count(*) from memberships where user_id = 2" gives 1

  Scenario Outline: A member who is not an administrator is refused, and nothing changes
    Given I sign in as "bea@example.com"
    When I post nothing to "<path>"
    Then the status is 403
    And the query "select count(*) from users where active = 1" gives 3
    And the query "select count(*) from accounts where join_code = 'aaaa-bbbb-cccc'" gives 1

    Examples:
      | path                |
      | /users/3/deactivate |
      | /users/3/reactivate |
      | /users/9/deactivate |
      | /account/join_code  |

  Scenario Outline: An administrator cannot deactivate themselves, and a person who is not there is a 404
    When I post nothing to "<path>"
    Then the status is <status>
    And the query "select count(*) from users where active = 1" gives 3

    Examples:
      | path                | status |
      | /users/1/deactivate | 403    |
      | /users/9/deactivate | 404    |
      | /users/9/reactivate | 404    |
      | /users/x/deactivate | 404    |

  Scenario: A bot is not a person to deactivate
    Given I run the sql "insert into users (name, role, bot_token) values ('Hook', 'bot', 'tok')"
    When I get "/users"
    Then the body does not contain "Hook"
    When I post nothing to "/users/4/deactivate"
    Then the status is 404
    And the query "select count(*) from users where id = 4 and active = 1" gives 1

  Scenario: A visitor with no session is sent to sign in, and nothing changes
    Given the browser has no cookies
    When I get "/users"
    Then the status is 302
    And the header "location" is "/session/new"
    When I post nothing to "/users/2/deactivate"
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from users where active = 1" gives 3

  Scenario Outline: A page of another site cannot deactivate or reactivate anybody
    Given I run the sql "update users set active = 0 where id = 3"
    And the request header "sec-fetch-site" is "cross-site"
    When I post nothing to "<path>"
    Then the status is 403
    And the query "select count(*) from users where active = 1" gives 2

    Examples:
      | path                |
      | /users/2/deactivate |
      | /users/3/reactivate |

  Scenario: A session is not opened for a person who was deactivated after their password was checked
    Given I run the sql "update users set active = 0 where id = 3"
    When Auth.open_session is asked for the user 3
    Then the session is refused
    And the query "select count(*) from sessions where user_id = 3" gives 0
    When Auth.open_session is asked for the user 2
    Then the session is opened
    And the query "select count(*) from sessions where user_id = 2" gives 1

  Scenario Outline: The check inside the transaction refuses an actor who is not an active administrator, and changes nothing
    Given I run the sql "insert into users (name, email, password_digest, role, active) values ('Di', 'di@example.com', 'x', 'administrator', 0)"
    And I run the sql "update users set active = 0 where id = 3"
    When "<actor>" asks Accounts to "<action>" the user <user>
    Then the change is refused
    And the query "select count(*) from users where id = 2 and active = 1" gives 1
    And the query "select count(*) from users where id = 3 and active = 0" gives 1
    And the query "select count(*) from accounts where join_code = 'aaaa-bbbb-cccc'" gives 1

    Examples:
      | actor           | action     | user |
      | bea@example.com | deactivate | 3    |
      | bea@example.com | reactivate | 3    |
      | bea@example.com | regenerate | 0    |
      | di@example.com  | deactivate | 2    |
      | di@example.com  | reactivate | 3    |
      | di@example.com  | regenerate | 0    |

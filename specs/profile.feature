Feature: The profile and the page of a user
  A person reads the page of any user (`UsersController#show`) and changes their own name, email address, password and
  bio at `/users/me/profile` (`Users::ProfilesController`). The picture is not changeable yet. A blank email or
  password is left as it is. The profile of another user is a 404 here (Rails ignores the id and edits the person who
  is signed in). The first admin is Ana, user 1; Bea is user 2 and Cy is user 3; Di (user 4) is deactivated and the bot
  Robo is user 5.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And a user "Di" with the email "di@example.com", the role "member" and the status "deactivated" exists
    And a bot "Robo" with the token "robo-token" exists
    And I run the sql "update users set bio = 'Likes tea' where id = 2"
    And I sign in as "bea@example.com"

  Scenario: The profile shows the form, the rooms and the way back to the user page, and is private
    When I get "/users/me/sidebar"
    Then the body contains "<a href=\"/users/me/profile\">Profile</a>"
    When I get "/users/me/profile"
    Then the status is 200
    And the header "cache-control" is "no-store"
    And the body contains "<h1>Your profile</h1>"
    And the body contains "<input name=\"_method\" type=\"hidden\" value=\"patch\">"
    And the body contains "<input name=\"user[name]\" type=\"text\" value=\"Bea\""
    And the body contains "<input name=\"user[email_address]\" type=\"email\" value=\"bea@example.com\""
    And the body contains "<input name=\"user[password]\" type=\"password\""
    And the body contains "Likes tea</textarea>"
    And the body contains "<a href=\"/rooms/1\">All Talk</a>"
    And the body contains "<a href=\"/rooms/1/involvement\">Sidebar</a>"
    When I get "/users/2/profile"
    Then the status is 200
    And the body contains "<h1>Your profile</h1>"

  Scenario Outline: Each field is saved, and the others stay
    When I post to "/users/me/profile" the form:
      | _method | patch   |
      | <field> | <value> |
    Then the status is 302
    And the header "location" is "/users/me/profile"
    And the query "<check>" gives 1
    And the query "select count(*) from users where id = 3 and name = 'Cy' and bio is null" gives 1

    Examples:
      | field               | value               | check                                                                                |
      | user[name]          | Bea Smith           | select count(*) from users where id = 2 and name = 'Bea Smith' and bio = 'Likes tea' |
      | user[email_address] | Bea.New@Example.com | select count(*) from users where id = 2 and email_address = 'bea.new@example.com'    |
      | user[bio]           | Reads a lot         | select count(*) from users where id = 2 and bio = 'Reads a lot' and name = 'Bea'     |
      | user[bio]           |                     | select count(*) from users where id = 2 and bio = '' and name = 'Bea'                |

  Scenario: A new password needs the current one, ends the other sessions and the push subscriptions, and keeps this one
    Given I run the sql "insert into push_subscriptions (endpoint, user_id, created_at, updated_at) values ('https://push.example/a', 2, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000'), ('https://push.example/b', 3, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And the browser saves a copy of its cookies
    And I sign in as "bea@example.com"
    When I post to "/users/me/profile" the form:
      | _method                  | patch                 |
      | user[password]           | a brand new password  |
      | user[password_challenge] | another long password |
    Then the status is 302
    And the header "location" is "/users/me/profile"
    And the query "select count(*) from users where id = 2 and password_digest not like 'a brand%'" gives 1
    And the query "select count(*) from sessions where user_id = 2" gives 1
    And the query "select count(*) from push_subscriptions where user_id = 2" gives 0
    And the query "select count(*) from push_subscriptions where user_id = 3" gives 1
    When I get "/users/me/profile"
    Then the status is 200
    When the browser restores its saved cookies
    And I get "/users/me/profile"
    Then the status is 302
    And the header "location" is "/session/new"
    When the browser has no cookies
    And I post to "/session" the form:
      | email_address | bea@example.com      |
      | password      | a brand new password |
    Then the status is 302
    And the header "location" is "/"
    When the browser has no cookies
    And I post to "/session" the form:
      | email_address | bea@example.com       |
      | password      | another long password |
    Then the status is 422

  Scenario Outline: A new password with a wrong or missing current password is refused and saves nothing
    When I post to "/users/me/profile" the form:
      | _method                  | patch                |
      | user[name]               | Bea Changed          |
      | user[password]           | a brand new password |
      | user[password_challenge] | <challenge>          |
    Then the status is 422
    And the body contains "Enter your current password to set a new one"
    And the body contains "Bea Changed"
    And the body does not contain "a brand new password"
    And the query "select count(*) from users where id = 2 and name = 'Bea'" gives 1
    And the query "select count(*) from sessions where user_id = 2" gives 1

    Examples:
      | challenge   |
      | not the one |
      |             |

  Scenario: The current password is tried a limited number of times by a person
    When I post to "/users/me/profile" 14 times at once the form:
      | _method                  | patch                |
      | user[password]           | a brand new password |
      | user[password_challenge] | not the one          |
    Then each status is one of "422, 429, 503"
    And at least one status is 429

  Scenario Outline: A part that does not do is refused with the form again, and nothing is saved
    When I post to "/users/me/profile" the form:
      | _method | patch   |
      | <field> | <value> |
    Then the status is 422
    And the body contains "<message>"
    And the body contains "<kept>"
    And the query "select count(*) from users where id = 2 and name = 'Bea' and email_address = 'bea@example.com' and bio = 'Likes tea'" gives 1

    Examples:
      | field               | value          | message                                   | kept           |
      | user[name]          |                | Enter your name                           | Likes tea      |
      | user[email_address] | not an email   | Enter a valid email address               | not an email   |
      | user[email_address] | CY@example.com | An account with that email exists already | CY@example.com |
      | user[email_address] | di@example.com | An account with that email exists already | Likes tea      |
      | user[password]      | short          | The password needs at least 8 characters  | Likes tea      |

  Scenario: The own address, a blank email and a blank password are not a change, and a form with no part is a 400
    When I post to "/users/me/profile" the form:
      | _method             | patch           |
      | user[email_address] | BEA@example.com |
      | user[password]      |                 |
    Then the status is 302
    And the query "select count(*) from users where id = 2 and email_address = 'bea@example.com'" gives 1
    When I post to "/users/me/profile" the form:
      | _method             | patch |
      | user[email_address] |       |
    Then the status is 302
    And the query "select count(*) from users where id = 2 and email_address = 'bea@example.com'" gives 1
    When I post to "/users/me/profile" the form:
      | _method | patch |
    Then the status is 400

  Scenario: A real PATCH, a real PUT and a post with put save, and any other post is a 405
    When I send a PATCH to "/users/me/profile" the form:
      | user[name] | Bea One |
    Then the status is 302
    When I send a PUT to "/users/2/profile" the form:
      | user[name] | Bea Two |
    Then the status is 302
    When I post to "/users/me/profile" the form:
      | _method    | PUT       |
      | user[name] | Bea Three |
    Then the status is 302
    And the query "select count(*) from users where id = 2 and name = 'Bea Three'" gives 1
    When I post to "/users/me/profile" the form:
      | _method    | delete |
      | user[name] | Nope   |
    Then the status is 405
    And the header "allow" is "GET, HEAD, POST, PATCH, PUT"
    When I send a DELETE to "/users/me/profile"
    Then the status is 405
    And the query "select count(*) from users where id = 2 and name = 'Bea Three'" gives 1

  Scenario: The profile of another user is a 404 to read and to save, and nothing of theirs changes
    When I get "/users/1/profile"
    Then the status is 404
    When I post to "/users/1/profile" the form:
      | _method    | patch  |
      | user[name] | Hacked |
    Then the status is 404
    When I send a PATCH to "/users/3/profile" the form:
      | user[name] | Hacked |
    Then the status is 404
    And the query "select count(*) from users where name = 'Hacked'" gives 0

  Scenario: A visitor is sent to sign in and a page of another site saves nothing
    Given the request header "sec-fetch-site" is "cross-site"
    When I post to "/users/me/profile" the form:
      | _method    | patch  |
      | user[name] | Forged |
    Then the status is 403
    When I send a PATCH to "/users/me/profile" the form:
      | user[name] | Forged |
    Then the status is 403
    And the query "select count(*) from users where name = 'Forged'" gives 0
    Given the request header "sec-fetch-site" is "same-origin"
    And the browser has no cookies
    When I get "/users/me/profile"
    Then the status is 302
    And the header "location" is "/session/new"
    When I get "/users/1"
    Then the status is 302
    When I post to "/users/me/profile" the form:
      | _method    | patch  |
      | user[name] | Nobody |
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from users where name = 'Nobody'" gives 0

  Scenario: The page of a user shows the name and bio to anybody, the email to an administrator, and a way to write
    When I get "/users/1"
    Then the status is 200
    And the body contains "<h1>Ana</h1>"
    And the body does not contain "ana@example.com"
    And the body contains "<input name=\"member\" type=\"hidden\" value=\"1\">"
    And the body does not contain "Edit my profile"
    When I get "/users/2"
    Then the body contains "Likes tea"
    And the body contains "<a href=\"/users/me/profile\">Edit my profile</a>"
    And the body does not contain "type=\"hidden\" value=\"2\""
    When I sign in as "ana@example.com"
    And I get "/users/2"
    Then the body contains "<a href=\"mailto:bea@example.com\">bea@example.com</a>"

  Scenario: A deactivated person and a bot have a page, and a user that does not exist has none
    When I get "/users/4"
    Then the status is 200
    And the body contains "Di is no longer on this account"
    And the body does not contain "di@example.com"
    And the body does not contain "name=\"member\""
    When I get "/users/5"
    Then the status is 200
    And the body contains "<input name=\"member\" type=\"hidden\" value=\"5\">"
    When I get "/users/99"
    Then the status is 404
    When I get "/users/abc"
    Then the status is 404
    When I get "/users/me"
    Then the status is 404

  Scenario: A name and a bio are text on the user page and the profile, never markup
    Given I run the sql "update users set name = '<script>alert(1)</script>', bio = '<img src=x onerror=alert(2)>' where id = 3"
    When I get "/users/3"
    Then the status is 200
    And the body does not contain "<script>alert(1)"
    And the body does not contain "<img src=x"
    And the body contains "&lt;script&gt;alert(1)"
    When I get "/users"
    Then the body does not contain "<script>alert(1)"

  Scenario: The people page links each name to the page of the user
    When I get "/users"
    Then the body contains "<a href=\"/users/1\">Ana</a>"
    And the body contains "<a href=\"/users/3\">Cy</a>"

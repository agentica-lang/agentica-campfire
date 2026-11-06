Feature: The account settings page
  The account has a name and people, as in Rails Campfire (`AccountsController`, `Accounts::UsersController`). Everybody
  who is signed in sees the name and the people at `/account/edit`. An administrator can rename the account, make a
  person an administrator or a member, and remove a person (which deactivates them, as `User#deactivate` does; the
  people page brings them back). The page shows neither switch for the person who looks, and the server refuses both
  for oneself, so the account always keeps an administrator. The first admin is Ana, user 1; Bea is user 2 and Cy is
  user 3; Di (user 4) is deactivated.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And a user "Di" with the email "di@example.com", the role "member" and the status "deactivated" exists

  Scenario: An administrator sees the name box, the administrators first, and a role switch and a button for the others
    When I get "/users/me/sidebar"
    Then the body contains "<a href=\"/account/edit\">Account</a>"
    When I get "/account/edit"
    Then the status is 200
    And the header "cache-control" is "no-store"
    And the body contains "<h1>Account settings</h1>"
    And the body contains "<input name=\"account[name]\" type=\"text\" value=\"Campfire\""
    And the body contains "action=\"/account\""
    And the body shows "Ana" before "Bea"
    And the body contains "bea@example.com"
    And the body contains "<input name=\"user[role]\" type=\"hidden\" value=\"administrator\">"
    And the body contains "Make administrator"
    And the body contains "action=\"/account/users/2\""
    And the body contains "action=\"/account/users/3\""
    And the body does not contain "action=\"/account/users/1\""
    And the body does not contain "Di"
    And the body does not contain "Make member"

  Scenario: A member sees the name and the people and no form
    Given I sign in as "bea@example.com"
    When I get "/account/edit"
    Then the status is 200
    And the body contains "<h2>Campfire</h2>"
    And the body contains "Ana"
    And the body contains "Cy"
    And the body does not contain "example.com"
    And the body does not contain "<form method=\"post\" action=\"/account"
    And the body does not contain "account[name]"

  Scenario: An administrator renames the account, by the form and by a real PATCH
    When I post to "/account" the form:
      | _method        | patch      |
      | account[name]  | Campfire HQ |
    Then the status is 302
    And the header "location" is "/account/edit"
    And the query "select count(*) from accounts where name = 'Campfire HQ'" gives 1
    When I get "/account/edit"
    Then the body contains "value=\"Campfire HQ\""
    When I send a PATCH to "/account" the form:
      | account[name] | Second Name |
    Then the status is 302
    And the query "select count(*) from accounts where name = 'Second Name'" gives 1
    When I sign in as "bea@example.com"
    And I get "/account/edit"
    Then the body contains "<h2>Second Name</h2>"

  Scenario Outline: A name that is blank or too long is refused with the form again
    When I post to "/account" the form:
      | _method       | patch  |
      | account[name] | <name> |
    Then the status is 422
    And the body contains "Give the account a name of 1 to 100 characters"
    And the query "select count(*) from accounts where name = 'Campfire'" gives 1

    Examples:
      | name |
      |      |
      |   |
      | xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx |

  Scenario: A member cannot rename the account, and is told so before the form is read
    Given I sign in as "bea@example.com"
    When I post to "/account" the form:
      | _method | patch |
    Then the status is 403
    When I send a PATCH to "/account" the form:
      | account[name] | Mine |
    Then the status is 403
    And the query "select count(*) from accounts where name = 'Campfire'" gives 1

  Scenario: A rename with no field is a 400
    When I post to "/account" the form:
      | _method | patch |
    Then the status is 400

  Scenario: An administrator makes a person an administrator and a member again
    When I post to "/account/users/2" the form:
      | _method   | patch         |
      | user[role] | administrator |
    Then the status is 302
    And the header "location" is "/account/edit"
    And the query "select count(*) from users where id = 2 and role = 1" gives 1
    When I get "/account/edit"
    Then the body contains "<span class=\"badge\">administrator</span>" 2 times
    And the body contains "Make member"
    When I sign in as "bea@example.com"
    And I get "/account/edit"
    Then the body contains "action=\"/account/users/3\""
    When I sign in as "ana@example.com"
    And I send a PATCH to "/account/users/2" the form:
      | user[role] | member |
    Then the status is 302
    And the query "select count(*) from users where id = 2 and role = 0" gives 1

  Scenario Outline: A role change that is not allowed changes nothing
    Given a user "Bot" with the email "bot@example.com", the role "member" and the status "active" exists
    And I run the sql "update users set role = 2 where id = 5"
    When I sign in as "<who>"
    And I post to "<path>" the form:
      | _method    | patch  |
      | user[role] | <role> |
    Then the status is <status>
    And the query "select count(*) from users where role = 1" gives 1

    Examples:
      | who               | path                | role          | status |
      | ana@example.com   | /account/users/1    | member        | 403    |
      | bea@example.com   | /account/users/3    | administrator | 403    |
      | bea@example.com   | /account/users/99   | administrator | 403    |
      | ana@example.com   | /account/users/99   | administrator | 404    |
      | ana@example.com   | /account/users/abc  | administrator | 404    |
      | ana@example.com   | /account/users/4    | administrator | 404    |
      | ana@example.com   | /account/users/5    | administrator | 404    |
      | ana@example.com   | /account/users/2    | owner         | 422    |
      | ana@example.com   | /account/users/2    |               | 422    |

  Scenario: A role change with no field is a 400, after the person is found
    When I post to "/account/users/2" the form:
      | _method | patch |
    Then the status is 400
    When I post to "/account/users/99" the form:
      | _method | patch |
    Then the status is 404

  Scenario: The last administrator cannot step down, and the account keeps one when two step on each other
    When I send a PATCH to "/account/users/1" the form:
      | user[role] | member |
    Then the status is 403
    And the query "select count(*) from users where role = 1" gives 1
    When I post to "/account/users/2" the form:
      | _method    | patch         |
      | user[role] | administrator |
    And I sign in as "bea@example.com"
    And I send a PATCH to "/account/users/1" the form:
      | user[role] | member |
    Then the status is 302
    When I send a PATCH to "/account/users/2" the form:
      | user[role] | member |
    Then the status is 403
    And the query "select count(*) from users where role = 1 and status = 0" gives 1
    And the query "select count(*) from users where id = 2 and role = 1" gives 1

  Scenario: An administrator removes a person, by the form and by a real DELETE, and the person cannot sign in
    Given I sign in as "bea@example.com"
    And the browser saves a copy of its cookies
    And I sign in as "ana@example.com"
    When I post to "/account/users/2" the form:
      | _method | delete |
    Then the status is 302
    And the header "location" is "/account/edit"
    And the query "select count(*) from users where id = 2 and status = 1" gives 1
    And the query "select count(*) from sessions where user_id = 2" gives 0
    When the browser restores its saved cookies
    And I get "/"
    Then the status is 302
    And the header "location" is "/session/new"
    When I sign in as "ana@example.com"
    And I send a DELETE to "/account/users/3"
    Then the status is 302
    And the query "select count(*) from users where id = 3 and status = 1" gives 1
    When I get "/account/edit"
    Then the body does not contain "Bea"
    And the body does not contain "Cy"

  Scenario Outline: A removal that is not allowed changes nothing
    When I sign in as "<who>"
    And I post to "<path>" the form:
      | _method | delete |
    Then the status is <status>
    And the query "select count(*) from users where status = 1" gives 1

    Examples:
      | who             | path               | status |
      | ana@example.com | /account/users/1   | 403    |
      | bea@example.com | /account/users/3   | 403    |
      | ana@example.com | /account/users/99  | 404    |
      | ana@example.com | /account/users/abc | 404    |

  Scenario: A visitor with no session is sent to sign in, and a page of another site changes nothing
    Given the browser has no cookies
    When I get "/account/edit"
    Then the status is 302
    And the header "location" is "/session/new"
    When I post to "/account" the form:
      | _method       | patch |
      | account[name] | Nope  |
    Then the status is 302
    And the header "location" is "/session/new"
    When I send a DELETE to "/account/users/2"
    Then the status is 302
    And the header "location" is "/session/new"
    Given I sign in as "ana@example.com"
    And the request header "sec-fetch-site" is "cross-site"
    When I post to "/account" the form:
      | _method       | patch |
      | account[name] | Nope  |
    Then the status is 403
    When I send a DELETE to "/account/users/2"
    Then the status is 403
    When I send a PATCH to "/account/users/2" the form:
      | user[role] | administrator |
    Then the status is 403
    And the query "select count(*) from accounts where name = 'Campfire'" gives 1
    And the query "select count(*) from users where role = 1 or status = 1" gives 2

  Scenario Outline: Another method is a 405 that lists the methods of the path
    When I post to "<path>" the form:
      | _method | <method> |
    Then the status is 405
    And the header "allow" is "<allow>"

    Examples:
      | path              | method | allow                |
      | /account          | put    | POST, PATCH          |
      | /account          |        | POST, PATCH          |
      | /account/users/2  | put    | POST, PATCH, DELETE  |
      | /account/users/2  |        | POST, PATCH, DELETE  |

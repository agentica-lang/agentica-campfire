Feature: The chat bots of the account
  An administrator manages the chat bots of the account at `/account/bots`, as in Rails Campfire
  (`Accounts::BotsController`, `Accounts::Bots::KeysController`, `User::Bot`): a bot is a user with the role `bot`, a name
  and a token of 12 letters and digits, and its key is `ID-TOKEN`. The administrator makes a bot (it joins the open rooms),
  sees its key, renames it, gives it a new key (the old one finds no bot) and deactivates it (it leaves the open and
  closed rooms and its key finds no bot). The webhook URL and the avatar of Rails' form are not here, and nor are the
  curl lines of the list, which need the messages API. Everything here is for administrators: anybody else is answered
  403 before the bot is looked at. The first admin is Ana, user 1, "All Talk" is room 1 (open); Bea is user 2 and the
  bot Robo is user 3 (token `aaaaBBBB1111`) in the scenarios that need one. Room 2 is the closed room "Secret" of Ana,
  Bea and Robo.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists

  Scenario: The account page of an administrator links to the bots, and the list starts empty
    When I get "/account/edit"
    Then the body contains "<a href=\"/account/bots\">Chat bots</a>"
    When I get "/account/bots"
    Then the status is 200
    And the header "cache-control" is "no-store"
    And the header "referrer-policy" is "no-referrer"
    And the body contains "<h1>Chat bots</h1>"
    And the body contains "There are no chat bots yet."
    And the body contains "<a href=\"/account/bots/new\">Add a chat bot</a>"
    When I sign in as "bea@example.com"
    And I get "/account/edit"
    Then the body does not contain "/account/bots"

  Scenario: An administrator makes a bot, which joins the open rooms and has a key of its id and a 12-character token
    When I get "/account/bots/new"
    Then the status is 200
    And the body contains "<h1>New chat bot</h1>"
    And the body contains "<form method=\"post\" action=\"/account/bots\">"
    And the body contains "name=\"user[name]\""
    When I post to "/account/bots" the form:
      | user[name] | Robo |
    Then the status is 302
    And the header "location" is "/account/bots"
    And the query "select count(*) from users where id = 3 and name = 'Robo' and role = 2 and status = 0 and email_address is null and password_digest is null" gives 1
    And the query "select count(*) from users where id = 3 and length(bot_token) = 12 and bot_token not glob '*[^A-Za-z0-9]*'" gives 1
    And the query "select count(*) from memberships where user_id = 3 and room_id = 1" gives 1
    When I run the sql "update users set bot_token = 'aaaaBBBB1111' where id = 3"
    And I get "/account/bots"
    Then the body contains "<span class=\"name\">Robo</span>"
    And the body contains "<code class=\"meta\">3-aaaaBBBB1111</code>"
    And the body contains "href=\"/account/bots/3/edit\""
    When I get "/users"
    Then the body does not contain "Robo"

  Scenario Outline: A name that is blank or too long is refused with the form again
    When I post to "/account/bots" the form:
      | user[name] | <name> |
    Then the status is 422
    And the body contains "Give the bot a name of 1 to 100 characters"
    And the query "select count(*) from users where role = 2" gives 0

    Examples:
      | name |
      |      |
      |   |
      | xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx |

  Scenario: An administrator renames a bot, by the form, a real PATCH and a real PUT, and the key stays
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    When I get "/account/bots/3/edit"
    Then the status is 200
    And the body contains "<h1>Edit chat bot</h1>"
    And the body contains "value=\"Robo\""
    And the body contains "<code>3-aaaaBBBB1111</code>"
    And the body contains "action=\"/account/bots/3\""
    When I post to "/account/bots/3" the form:
      | _method    | patch |
      | user[name] | Robbie |
    Then the status is 302
    And the header "location" is "/account/bots"
    And the query "select count(*) from users where id = 3 and name = 'Robbie' and bot_token = 'aaaaBBBB1111'" gives 1
    When I send a PATCH to "/account/bots/3" the form:
      | user[name] | Second |
    Then the status is 302
    When I send a PUT to "/account/bots/3" the form:
      | user[name] | Third |
    Then the status is 302
    And the query "select count(*) from users where id = 3 and name = 'Third'" gives 1
    When I get "/account/bots"
    Then the body contains "<span class=\"name\">Third</span>"

  Scenario: A rename to a blank name is refused with the form again
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    When I send a PATCH to "/account/bots/3" the form:
      | user[name] |   |
    Then the status is 422
    And the body contains "Give the bot a name of 1 to 100 characters"
    And the query "select count(*) from users where id = 3 and name = 'Robo'" gives 1

  Scenario: A new key makes the old one find no bot
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    When I post to "/account/bots/3/key" the form:
      | _method | put |
    Then the status is 302
    And the header "location" is "/account/bots"
    And the query "select count(*) from users where role = 2 and status = 0 and id = 3 and bot_token = 'aaaaBBBB1111'" gives 0
    And the query "select count(*) from users where id = 3 and length(bot_token) = 12 and bot_token not glob '*[^A-Za-z0-9]*'" gives 1
    When I get "/account/bots"
    Then the body does not contain "aaaaBBBB1111"
    And the body contains "<code class=\"meta\">3-"
    When I run the sql "update users set bot_token = 'ccccDDDD2222' where id = 3"
    And I send a PUT to "/account/bots/3/key"
    Then the status is 302
    And the query "select count(*) from users where id = 3 and bot_token <> 'ccccDDDD2222'" gives 1

  Scenario: Deactivating a bot takes it out of the list and the shared rooms and kills its key
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    And a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And I run the sql "insert into memberships (room_id, user_id, created_at, updated_at) values (1, 3, 'now', 'now'), (2, 3, 'now', 'now')"
    When I get "/account/bots/3/edit"
    Then the body contains "action=\"/account/bots/3\""
    When I post to "/account/bots/3" the form:
      | _method | delete |
    Then the status is 302
    And the header "location" is "/account/bots"
    And the query "select count(*) from users where id = 3 and status = 1 and role = 2" gives 1
    And the query "select count(*) from users where role = 2 and status = 0 and id = 3 and bot_token = 'aaaaBBBB1111'" gives 0
    And the query "select count(*) from memberships where user_id = 3" gives 0
    When I get "/account/bots"
    Then the body does not contain "Robo"
    And the body contains "There are no chat bots yet."
    When I send a DELETE to "/account/bots/3"
    Then the status is 404

  Scenario Outline: A page of a bot that is not an active bot is a 404
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    And a bot "Gone" with the token "ggggHHHH3333" exists
    And I run the sql "update users set status = 1 where id = 4"
    When I get "<path>"
    Then the status is 404

    Examples:
      | path                   |
      | /account/bots/abc/edit |
      | /account/bots/2/edit   |
      | /account/bots/4/edit   |

  Scenario Outline: A change of a bot that is not an active bot is a 404 and changes nothing
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    And a bot "Gone" with the token "ggggHHHH3333" exists
    And I run the sql "update users set status = 1 where id = 4"
    When I post to "<path>" the form:
      | _method    | <method> |
      | user[name] | Other    |
    Then the status is 404
    And the query "select count(*) from users where name = 'Other'" gives 0
    And the query "select count(*) from users where status = 0 and role = 2" gives 1
    And the query "select count(*) from users where bot_token in ('aaaaBBBB1111', 'ggggHHHH3333')" gives 2

    Examples:
      | path                   | method |
      | /account/bots/abc      | patch  |
      | /account/bots/4        | patch  |
      | /account/bots/2        | delete |
      | /account/bots/4        | delete |
      | /account/bots/2/key    | put    |
      | /account/bots/4/key    | put    |

  Scenario: A change with no name is a 400, after the bot is found
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    When I post to "/account/bots" the form:
      | x | y |
    Then the status is 400
    When I post to "/account/bots/3" the form:
      | _method | patch |
    Then the status is 400
    When I post to "/account/bots/99" the form:
      | _method | patch |
    Then the status is 404

  Scenario Outline: A member is answered 403 on every route, before the bot or the form is looked at
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    When I sign in as "bea@example.com"
    And I get "<page>"
    Then the status is 403
    When I post to "<path>" the form:
      | _method    | <method> |
      | user[name] | Other    |
    Then the status is 403
    And the query "select count(*) from users where role = 2 and status = 0 and name = 'Robo' and bot_token = 'aaaaBBBB1111'" gives 1
    And the query "select count(*) from users where role = 2" gives 1

    Examples:
      | page                  | path                 | method |
      | /account/bots         | /account/bots        |        |
      | /account/bots/new     | /account/bots/3      | patch  |
      | /account/bots/3/edit  | /account/bots/3      | delete |
      | /account/bots/99/edit | /account/bots/99     | delete |
      | /account/bots/abc/edit | /account/bots/3/key | put    |
      | /account/bots/3/edit  | /account/bots/99/key | put    |

  Scenario: A member is answered 403 for the real verbs too
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    When I sign in as "bea@example.com"
    And I send a PATCH to "/account/bots/3" the form:
      | user[name] | Other |
    Then the status is 403
    When I send a PUT to "/account/bots/3" the form:
      | user[name] | Other |
    Then the status is 403
    When I send a DELETE to "/account/bots/3"
    Then the status is 403
    When I send a PUT to "/account/bots/3/key"
    Then the status is 403
    And the query "select count(*) from users where role = 2 and status = 0 and name = 'Robo' and bot_token = 'aaaaBBBB1111'" gives 1

  Scenario: A visitor with no session is sent to sign in, and a page of another site changes nothing
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    And the browser has no cookies
    When I get "/account/bots"
    Then the status is 302
    And the header "location" is "/session/new"
    When I post to "/account/bots" the form:
      | user[name] | Nope |
    Then the status is 302
    And the header "location" is "/session/new"
    When I send a DELETE to "/account/bots/3"
    Then the status is 302
    And the header "location" is "/session/new"
    When I send a PUT to "/account/bots/3/key"
    Then the status is 302
    And the header "location" is "/session/new"
    Given I sign in as "ana@example.com"
    And the request header "sec-fetch-site" is "cross-site"
    When I post to "/account/bots" the form:
      | user[name] | Nope |
    Then the status is 403
    When I send a PATCH to "/account/bots/3" the form:
      | user[name] | Nope |
    Then the status is 403
    When I send a DELETE to "/account/bots/3"
    Then the status is 403
    When I send a PUT to "/account/bots/3/key"
    Then the status is 403
    And the query "select count(*) from users where role = 2 and status = 0 and name = 'Robo' and bot_token = 'aaaaBBBB1111'" gives 1

  Scenario Outline: Another method is a 405 that lists the methods of the path
    When I post to "<path>" the form:
      | _method | <method> |
    Then the status is 405
    And the header "allow" is "<allow>"

    Examples:
      | path                | method | allow                |
      | /account/bots/3     | get    | POST, PATCH, PUT, DELETE |
      | /account/bots/3     |        | POST, PATCH, PUT, DELETE |
      | /account/bots/3/key | patch  | POST, PUT            |
      | /account/bots/3/key |        | POST, PUT            |

  Scenario Outline: The check inside the transaction refuses a member
    Given a bot "Robo" with the token "aaaaBBBB1111" exists
    When "bea@example.com" asks Bots to "<action>" the bot 3
    Then the change is refused
    And the query "select count(*) from users where role = 2 and status = 0 and name = 'Robo' and bot_token = 'aaaaBBBB1111'" gives 1

    Examples:
      | action     |
      | create     |
      | rename     |
      | reset_key  |
      | deactivate |

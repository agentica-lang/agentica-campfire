Feature: Who may create rooms
  The account can let only administrators make a shared room (`restrict_room_creation_to_administrators`, kept in the
  JSON of `accounts.settings` as Rails keeps it). With the setting on, `Rooms::OpensController` and `ClosedsController`
  answer 403 to a member on the form and on the post, and the sidebar leaves out the links to them; an administrator is
  not affected. A direct message is not restricted, as in Rails (its controller has no such filter). An administrator
  switches the setting on the account page (`PATCH /account` with `account[settings][...]`, as Rails' form sends it).
  The first admin is Ana, user 1; Bea is user 2 and Cy is user 3.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists

  Scenario: By default everybody may, and the sidebar has the links
    Given I sign in as "bea@example.com"
    When I get "/users/me/sidebar"
    Then the body contains "<a href=\"/rooms/new\">New room</a>"
    And the body contains "<a href=\"/closed_rooms/new\">New closed room</a>"
    When I get "/rooms/new"
    Then the status is 200
    When I post to "/rooms" the form:
      | name | Lunch |
    Then the status is 302

  Scenario: The account page of an administrator has the switch, and a member's has none
    When I get "/account/edit"
    Then the body contains "Who can create rooms: <strong>everybody</strong>"
    And the body contains "<input name=\"account[settings][restrict_room_creation_to_administrators]\" type=\"hidden\" value=\"true\">"
    When I sign in as "bea@example.com"
    And I get "/account/edit"
    Then the body does not contain "Who can create rooms"
    And the body does not contain "restrict_room_creation"

  Scenario: An administrator turns the restriction on and off, by the form and by a real PATCH
    Given I run the sql "update accounts set settings = '{\"other\":1}'"
    When I post to "/account" the form:
      | _method                                                         | patch |
      | account[settings][restrict_room_creation_to_administrators]     | true  |
    Then the status is 302
    And the header "location" is "/account/edit"
    And the query "select count(*) from accounts where json_extract(settings, '$.restrict_room_creation_to_administrators') = 1" gives 1
    And the query "select count(*) from accounts where json_extract(settings, '$.other') = 1" gives 1
    When I get "/account/edit"
    Then the body contains "Who can create rooms: <strong>administrators only</strong>"
    And the body contains "type=\"hidden\" value=\"false\""
    When I send a PATCH to "/account" the form:
      | account[settings][restrict_room_creation_to_administrators] | false |
    Then the status is 302
    And the query "select count(*) from accounts where json_extract(settings, '$.restrict_room_creation_to_administrators') = 0" gives 1
    And the query "select count(*) from accounts where json_extract(settings, '$.other') = 1" gives 1

  Scenario: The name and the switch are saved together, and either alone leaves the other as it was
    When I post to "/account" the form:
      | _method                                                         | patch   |
      | account[name]                                                   | Camp HQ |
      | account[settings][restrict_room_creation_to_administrators]     | true    |
    Then the status is 302
    And the query "select count(*) from accounts where name = 'Camp HQ' and json_extract(settings, '$.restrict_room_creation_to_administrators') = 1" gives 1
    When I send a PATCH to "/account" the form:
      | account[name] | Camp Two |
    Then the query "select count(*) from accounts where name = 'Camp Two' and json_extract(settings, '$.restrict_room_creation_to_administrators') = 1" gives 1

  Scenario: With the restriction on a member gets 403 on the two forms and the two posts, and makes nothing
    Given I run the sql "update accounts set settings = '{\"restrict_room_creation_to_administrators\":true}'"
    And I sign in as "bea@example.com"
    When I get "/rooms/new"
    Then the status is 403
    And the body is "Forbidden"
    When I get "/closed_rooms/new"
    Then the status is 403
    When I post to "/rooms" the form:
      | name | Lunch |
    Then the status is 403
    When I post to "/closed_rooms" the form:
      | name   | Secret |
      | member | 3      |
    Then the status is 403
    When I post nothing to "/rooms"
    Then the status is 403
    When I post nothing to "/closed_rooms"
    Then the status is 403
    And the query "select count(*) from rooms" gives 1

  Scenario: With the restriction on the sidebar of a member leaves out the links and keeps the direct message
    Given I run the sql "update accounts set settings = '{\"restrict_room_creation_to_administrators\":true}'"
    And I sign in as "bea@example.com"
    When I get "/users/me/sidebar"
    Then the body does not contain "New room"
    And the body does not contain "New closed room"
    And the body contains "<a href=\"/direct_rooms/new\">New direct message</a>"
    When I sign in as "ana@example.com"
    And I get "/users/me/sidebar"
    Then the body contains "<a href=\"/rooms/new\">New room</a>"
    And the body contains "<a href=\"/closed_rooms/new\">New closed room</a>"

  Scenario: With the restriction on an administrator makes both kinds, and anybody makes a direct message
    Given I run the sql "update accounts set settings = '{\"restrict_room_creation_to_administrators\":true}'"
    When I post to "/rooms" the form:
      | name | Lunch |
    Then the status is 302
    When I post to "/closed_rooms" the form:
      | name   | Secret |
      | member | 2      |
    Then the status is 302
    When I sign in as "bea@example.com"
    And I get "/direct_rooms/new"
    Then the status is 200
    When I post to "/direct_rooms" the form:
      | member | 3 |
    Then the status is 302
    And the query "select count(*) from rooms where type = 'Rooms::Direct'" gives 1

  Scenario Outline: A settings column that is empty, has no key or is not JSON restricts nobody
    Given I run the sql "update accounts set settings = <settings>"
    And I sign in as "bea@example.com"
    When I get "/rooms/new"
    Then the status is 200

    Examples:
      | settings                                      |
      | null                                          |
      | '{}'                                          |
      | 'not json'                                    |
      | json_object('restrict_room_creation_to_administrators', json('false')) |
      | json_object('restrict_room_creation_to_administrators', 'false')       |

  Scenario Outline: Saving the switch over settings that are not a JSON object starts them over
    Given I run the sql "update accounts set settings = <settings>"
    And I sign in as "ana@example.com"
    When I post to "/account" the form:
      | _method                                                         | patch |
      | account[settings][restrict_room_creation_to_administrators]     | true  |
    Then the status is 302
    And the query "select count(*) from accounts where json_extract(settings, '$.restrict_room_creation_to_administrators') = 1" gives 1

    Examples:
      | settings   |
      | null       |
      | '[1]'      |
      | '5'        |
      | 'not json' |

  Scenario: A member cannot change the switch, and a value that is not true or false is refused
    Given I sign in as "bea@example.com"
    When I post to "/account" the form:
      | _method                                                         | patch |
      | account[settings][restrict_room_creation_to_administrators]     | true  |
    Then the status is 403
    When I sign in as "ana@example.com"
    And I post to "/account" the form:
      | _method                                                         | patch |
      | account[settings][restrict_room_creation_to_administrators]     | maybe |
    Then the status is 422
    And the body contains "Choose on or off"
    And the query "select count(*) from accounts where settings is null or json_extract(settings, '$.restrict_room_creation_to_administrators') is null" gives 1

  Scenario: A visitor with no session and a page of another site cannot change the switch
    Given the browser has no cookies
    When I post to "/account" the form:
      | _method                                                         | patch |
      | account[settings][restrict_room_creation_to_administrators]     | true  |
    Then the status is 302
    And the header "location" is "/session/new"
    Given I sign in as "ana@example.com"
    And the request header "sec-fetch-site" is "cross-site"
    When I post to "/account" the form:
      | _method                                                         | patch |
      | account[settings][restrict_room_creation_to_administrators]     | true  |
    Then the status is 403
    And the query "select count(*) from accounts where settings is null or json_extract(settings, '$.restrict_room_creation_to_administrators') is null" gives 1

  Scenario: A visitor with no session is sent to sign in on the creation routes
    Given the browser has no cookies
    When I get "/rooms/new"
    Then the status is 302
    And the header "location" is "/session/new"
    When I post nothing to "/closed_rooms"
    Then the status is 302
    And the header "location" is "/session/new"

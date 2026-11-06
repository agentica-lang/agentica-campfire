Feature: Settings of open rooms, and converting between open and closed
  An open room has settings too: its maker and an account administrator can rename it, and can give only some people
  access to it, which makes it closed, as in Rails Campfire (`Rooms::OpensController#update` and
  `Rooms::ClosedsController#update`, which `becomes!` the other type). A closed room can be given to everyone, which
  makes it open and puts every active person in it. The settings are one page and one form: the form that is saved says
  what the room is to be (`type`), and a link on the page draws the form of the other kind. A direct room has no
  settings and never converts. The first admin is Ana, user 1, and "All Talk" is room 1; Bea is user 2 and Cy is
  user 3, and Di (user 4) is not active. Bea makes the open room "Lunch", room 2, so Ana is not its maker.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And a user "Di" with the email "di@example.com", the role "member" and the status "deactivated" exists
    And I sign in as "bea@example.com"
    And I post to "/rooms" the form:
      | name | Lunch |

  Scenario: The settings of an open room have the name, a way to give only some access, and the delete button
    When I get "/rooms/2/settings"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/rooms/2/settings\">"
    And the body contains "name=\"type\" type=\"hidden\" value=\"open\""
    And the body contains "value=\"Lunch\""
    And the body contains "Everyone on the account is in this room."
    And the body contains "<a href=\"/rooms/2/settings?type=closed\">Give only some access to this room</a>"
    And the body contains "Delete room"
    And the body does not contain "type=\"checkbox\""
    When I get "/rooms/2"
    Then the body contains "<a href=\"/rooms/2/settings\">Settings</a>"

  Scenario: The maker renames an open room, and it stays open with everybody in it
    When I post to "/rooms/2/settings" the form:
      | type | open       |
      | name | Lunch time |
    Then the status is 302
    And the header "location" is "/rooms/2"
    And the query "select count(*) from rooms where id = 2 and name = 'Lunch time' and type = 'Rooms::Open'" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 3
    When I get "/rooms/2"
    Then the body contains "<h1>Lunch time</h1>"

  Scenario: A form with no type, or one that is none of the two, only renames and keeps the room as it is
    When I post to "/rooms/2/settings" the form:
      | name | One |
    Then the status is 302
    When I post to "/rooms/2/settings" the form:
      | type | secret |
      | name | Two    |
    Then the status is 302
    And the query "select count(*) from rooms where id = 2 and name = 'Two' and type = 'Rooms::Open'" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 3

  Scenario: An administrator who is not the maker converts an open room to a closed one with a member list
    When I sign in as "ana@example.com"
    And I get "/rooms/2/settings?type=closed"
    Then the status is 200
    And the body contains "name=\"type\" type=\"hidden\" value=\"closed\""
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"2\" checked>"
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"3\" checked>"
    And the body contains "name=\"was\" type=\"hidden\" value=\"2\""
    And the body contains "<a href=\"/rooms/2/settings?type=open\">Give everyone access to this room</a>"
    When I post to "/rooms/2/settings" the form:
      | type   | closed |
      | name   | Lunch  |
      | member | 3      |
      | was    | 2      |
      | was    | 3      |
    Then the status is 302
    And the query "select count(*) from rooms where id = 2 and type = 'Rooms::Closed'" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id in (1, 3)" gives 2
    And the query "select count(*) from memberships where room_id = 2" gives 2
    When I sign in as "bea@example.com"
    And I get "/rooms/2"
    Then the status is 404
    When I sign in as "cy@example.com"
    And I get "/rooms/2"
    Then the status is 200

  Scenario: A form that was drawn before someone joined does not take them out when it converts the room
    When I sign in as "ana@example.com"
    And I post to "/rooms/2/settings" the form:
      | type   | closed |
      | name   | Lunch  |
      | member | 2      |
      | was    | 2      |
    Then the status is 302
    And the query "select count(*) from rooms where id = 2 and type = 'Rooms::Closed'" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 3

  Scenario: A closed room given to everyone becomes open, with every active person in it and the others as they were
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And I run the sql "update memberships set involvement = 'everything' where room_id = 3 and user_id = 2"
    When I sign in as "ana@example.com"
    And I get "/rooms/3/settings?type=open"
    Then the status is 200
    And the body contains "name=\"type\" type=\"hidden\" value=\"open\""
    And the body does not contain "type=\"checkbox\""
    When I post to "/rooms/3/settings" the form:
      | type | open   |
      | name | Secret |
    Then the status is 302
    And the query "select count(*) from rooms where id = 3 and type = 'Rooms::Open'" gives 1
    And the query "select count(*) from memberships where room_id = 3" gives 3
    And the query "select count(*) from memberships where room_id = 3 and user_id = 4" gives 0
    And the query "select count(*) from memberships where room_id = 3 and user_id = 2 and involvement = 'everything'" gives 1
    When I sign in as "cy@example.com"
    And I get "/rooms/3"
    Then the status is 200

  Scenario: A room that is converted to open and back is closed, with the people that the first conversion put in
    Given a closed room "Secret" with the members "ana@example.com"
    When I sign in as "ana@example.com"
    And I post to "/rooms/3/settings" the form:
      | type | open   |
      | name | Secret |
    Then the status is 302
    When I post to "/rooms/3/settings" the form:
      | type | closed |
      | name | Secret |
    Then the status is 302
    And the query "select count(*) from rooms where id = 3 and type = 'Rooms::Closed'" gives 1
    And the query "select count(*) from memberships where room_id = 3" gives 3

  Scenario: Another member of an open room cannot see the settings or change them, and gets no link
    When I sign in as "cy@example.com"
    And I get "/rooms/2"
    Then the body does not contain "/rooms/2/settings"
    When I get "/rooms/2/settings"
    Then the status is 403
    And the body is "Forbidden"
    When I get "/rooms/2/settings?type=closed"
    Then the status is 403
    When I post to "/rooms/2/settings" the form:
      | type   | closed |
      | name   | Mine   |
      | member | 1      |
      | was    | 2      |
    Then the status is 403
    And the query "select count(*) from rooms where id = 2 and name = 'Lunch' and type = 'Rooms::Open'" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 3

  Scenario Outline: A direct room has no settings and never converts, whatever the form says
    Given a direct room with the members "ana@example.com, bea@example.com"
    When I sign in as "ana@example.com"
    And I <step> "/rooms/3/settings<query>"
    Then the status is 404
    And the body is "Not Found"
    And the query "select count(*) from rooms where id = 3 and type = 'Rooms::Direct' and name is null" gives 1
    And the query "select count(*) from memberships where room_id = 3" gives 2

    Examples:
      | step | query        |
      | get  |              |
      | get  | ?type=open   |
      | get  | ?type=closed |

  Scenario Outline: A form that converts a direct room is refused before its fields are read
    Given a direct room with the members "ana@example.com, bea@example.com"
    When I sign in as "ana@example.com"
    And I post to "/rooms/3/settings" the form:
      | type | <type>   |
      | name | Hijacked |
    Then the status is 404
    And the query "select count(*) from rooms where id = 3 and type = 'Rooms::Direct' and name is null" gives 1
    And the query "select count(*) from memberships where room_id = 3" gives 2

    Examples:
      | type   |
      | open   |
      | closed |

  Scenario: A person who is not in the room, a name that is refused and a visitor
    Given a closed room "Secret" with the members "ana@example.com"
    When I get "/rooms/3/settings"
    Then the status is 404
    When I post to "/rooms/3/settings" the form:
      | type | open |
      | name | Mine |
    Then the status is 404
    And the query "select count(*) from rooms where id = 3 and name = 'Secret' and type = 'Rooms::Closed'" gives 1
    When I sign in as "ana@example.com"
    And I post to "/rooms/2/settings" the form:
      | type | closed |
      | name |        |
      | was  | 2      |
    Then the status is 422
    And the body contains "Give the room a name of 1 to 100 characters"
    And the body contains "name=\"type\" type=\"hidden\" value=\"closed\""
    And the query "select count(*) from rooms where id = 2 and type = 'Rooms::Open'" gives 1
    Given the browser has no cookies
    When I post to "/rooms/2/settings" the form:
      | type | closed |
      | name | Hijack |
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: A page of another site cannot convert a room
    When I sign in as "ana@example.com"
    And the request header "sec-fetch-site" is "cross-site"
    And I post to "/rooms/2/settings" the form:
      | type | closed |
      | name | Hijack |
    Then the status is 403
    And the query "select count(*) from rooms where id = 2 and type = 'Rooms::Open'" gives 1

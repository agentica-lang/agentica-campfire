Feature: Closed rooms
  A closed room has the people that its maker picked, and only them: the maker is always in it, and a person who is not
  in it gets 404, as for a room that was never made. Only its maker and an account administrator can rename it and
  change who is in it: another member gets 403. The first admin is Ana, user 1, an administrator, and "All Talk" is
  room 1; Bea is user 2 and Cy is user 3, so the first room that a scenario makes is room 2. Di (user 4) is an
  inactive person.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And I run the sql "insert into users (name, email, password_digest, active) values ('Di', 'di@example.com', 'x', 0)"

  Scenario: The form of a closed room lists the active people, and the sidebar has the way to it
    When I get "/"
    Then the body contains "<a href=\"/closed_rooms/new\">New closed room</a>"
    When I get "/closed_rooms/new"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/closed_rooms\">"
    And the body contains "name=\"name\""
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"2\">"
    And the body contains "Bea"
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"3\">"
    And the body does not contain "value=\"1\""
    And the body does not contain "Di"

  Scenario: Only the chosen people are in the room that is made, and the maker is one of them
    When I post to "/closed_rooms" the form:
      | name   | Secret |
      | member | 2      |
    Then the status is 302
    And the header "location" is "/rooms/2"
    And the query "select count(*) from rooms where (id, kind, name, creator_id) = (2, 'closed', 'Secret', 1)" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 2
    And the query "select count(*) from memberships where room_id = 2 and user_id in (1, 2)" gives 2
    When I get "/rooms/2"
    Then the status is 200
    And the body contains "<h1>Secret</h1>"
    When I sign in as "bea@example.com"
    And I get "/"
    Then the body contains "<a href=\"/rooms/2\">Secret</a>"
    When I post to "/rooms/2/messages" the form:
      | body | Hi Ana |
    Then the status is 302
    When I sign in as "cy@example.com"
    And I get "/"
    Then the body does not contain "Secret"
    When I get "/rooms/2"
    Then the status is 404
    And the body is "Not Found"

  Scenario: A closed room can have only its maker
    When I post to "/closed_rooms" the form:
      | name | Notes |
    Then the status is 302
    And the query "select count(*) from memberships where room_id = 2" gives 1

  Scenario: The name of the room is text, and the form that refuses it gives back what was typed and chosen
    When I post to "/closed_rooms" the form:
      | name   | <b>"Plans" & more</b> |
      | member | 3                     |
    Then the status is 302
    When I get "/rooms/2/settings"
    Then the body contains "value=\"&lt;b&gt;&quot;Plans&quot; &amp; more&lt;/b&gt;\""
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"3\" checked>"
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"2\">"
    And the body does not contain "<b>"

  Scenario Outline: A closed room needs a name of 1 to 100 characters
    When I post to "/closed_rooms" the form:
      | name   | <name> |
      | member | 2      |
    Then the status is 422
    And the body contains "Give the room a name of 1 to 100 characters"
    And the body contains "name=\"member\" value=\"2\" checked>"
    And the body contains "name=\"member\" value=\"3\">"
    And the query "select count(*) from rooms" gives 1

    Examples:
      | name                                                                                                  |
      |                                                                                                       |
      | xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx |

  Scenario: A chosen id that is not an active person is left out, and one that is not a number is refused
    When I post to "/closed_rooms" the form:
      | name   | Odd |
      | member | 1   |
      | member | 4   |
      | member | 99  |
    Then the status is 302
    And the query "select count(*) from memberships where room_id = 2" gives 1
    When I post to "/closed_rooms" the form:
      | name   | Odd2 |
      | member | abc  |
    Then the status is 400
    And the query "select count(*) from rooms" gives 2

  Scenario Outline: A visitor with no session is sent to sign in
    Given the browser has no cookies
    When I get "<path>"
    Then the status is 302
    And the header "location" is "/session/new"

    Examples:
      | path                |
      | /closed_rooms/new   |
      | /rooms/1/settings   |

  Scenario: A form from a visitor with no session changes nothing
    Given the browser has no cookies
    When I post to "/closed_rooms" the form:
      | name   | Secret |
      | member | 2      |
    Then the status is 302
    And the header "location" is "/session/new"
    When I post to "/rooms/1/settings" the form:
      | name | Hijacked |
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from rooms" gives 1
    And the query "select count(*) from rooms where name = 'All Talk'" gives 1

  Scenario: A page of another site cannot make a closed room
    Given the request header "sec-fetch-site" is "cross-site"
    When I post to "/closed_rooms" the form:
      | name   | Secret |
      | member | 2      |
    Then the status is 403
    And the query "select count(*) from rooms" gives 1

  Scenario: A closed room has a settings page that shows its name and who is in it
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    When I get "/rooms/2"
    Then the body contains "<a href=\"/rooms/2/settings\">Settings</a>"
    When I get "/rooms/2/settings"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/rooms/2/settings\">"
    And the body contains "value=\"Secret\""
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"2\" checked>"
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"3\">"
    And the body contains "name=\"was\" type=\"hidden\" value=\"2\""
    And the body does not contain "name=\"was\" type=\"hidden\" value=\"3\""

  Scenario: A member renames the room and adds and removes people
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    When I post to "/rooms/2/settings" the form:
      | name   | Plans |
      | member | 3     |
      | was    | 2     |
    Then the status is 302
    And the header "location" is "/rooms/2"
    And the query "select count(*) from rooms where id = 2 and name = 'Plans' and creator_id = 1" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id in (1, 3)" gives 2
    And the query "select count(*) from memberships where room_id = 2" gives 2
    When I get "/rooms/2"
    Then the body contains "<h1>Plans</h1>"
    When I sign in as "bea@example.com"
    And I get "/rooms/2"
    Then the status is 404
    When I sign in as "cy@example.com"
    And I get "/rooms/2"
    Then the status is 200

  Scenario: An administrator who is not the maker can change the room, and a form cannot take out its sender
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And I run the sql "update users set role = 'administrator' where id = 2"
    When I sign in as "bea@example.com"
    And I post to "/rooms/2/settings" the form:
      | name   | Renamed |
      | member | 3       |
      | was    | 1       |
      | was    | 2       |
    Then the status is 302
    And the query "select count(*) from rooms where id = 2 and name = 'Renamed' and creator_id = 1" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id = 1" gives 0
    And the query "select count(*) from memberships where room_id = 2 and user_id = 2" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id = 3" gives 1

  Scenario: The maker of a room changes it without being an administrator, and the other members cannot
    Given a closed room "Secret" with the members "bea@example.com, cy@example.com, ana@example.com"
    When I sign in as "bea@example.com"
    And I get "/rooms/2"
    Then the body contains "<a href=\"/rooms/2/settings\">Settings</a>"
    When I post to "/rooms/2/settings" the form:
      | name | Bea room |
    Then the status is 302
    When I sign in as "cy@example.com"
    And I get "/rooms/2"
    Then the status is 200
    And the body contains "<h1>Bea room</h1>"
    And the body does not contain "/rooms/2/settings"
    When I get "/rooms/2/settings"
    Then the status is 403
    And the body is "Forbidden"
    When I post to "/rooms/2/settings" the form:
      | name   | Cy room |
      | member | 3    |
      | was    | 1    |
    Then the status is 403
    When I post nothing to "/rooms/2/settings"
    Then the status is 403
    And the query "select count(*) from rooms where name = 'Bea room'" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 3
    When I sign in as "ana@example.com"
    And I get "/rooms/2"
    Then the body contains "<a href=\"/rooms/2/settings\">Settings</a>"
    When I get "/rooms/2/settings"
    Then the status is 200

  Scenario: A form that was drawn before someone was added keeps them
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And I run the sql "update users set role = 'administrator' where id = 2"
    When I get "/rooms/2/settings"
    Then the body contains "name=\"was\" type=\"hidden\" value=\"2\""
    When I sign in as "bea@example.com"
    And I post to "/rooms/2/settings" the form:
      | name   | Secret |
      | member | 1      |
      | member | 3      |
      | was    | 1      |
    Then the status is 302
    And the query "select count(*) from memberships where room_id = 2 and user_id = 3" gives 1
    When I sign in as "ana@example.com"
    And I post to "/rooms/2/settings" the form:
      | name   | Renamed |
      | member | 2       |
      | was    | 2       |
    Then the status is 302
    And the query "select count(*) from rooms where id = 2 and name = 'Renamed'" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id in (1, 2, 3)" gives 3

  Scenario: A form that was drawn before someone was taken out does not bring them back
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com, cy@example.com"
    And I run the sql "update users set role = 'administrator' where id = 2"
    When I get "/rooms/2/settings"
    Then the body contains "name=\"was\" type=\"hidden\" value=\"3\""
    When I sign in as "bea@example.com"
    And I post to "/rooms/2/settings" the form:
      | name   | Secret |
      | member | 1      |
      | was    | 1      |
      | was    | 3      |
    Then the status is 302
    And the query "select count(*) from memberships where room_id = 2 and user_id = 3" gives 0
    When I sign in as "ana@example.com"
    And I post to "/rooms/2/settings" the form:
      | name   | Renamed |
      | member | 2       |
      | member | 3       |
      | was    | 2       |
      | was    | 3       |
    Then the status is 302
    And the query "select count(*) from rooms where id = 2 and name = 'Renamed'" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id = 3" gives 0
    And the query "select count(*) from memberships where room_id = 2" gives 2

  Scenario: Naming an inactive person, a stranger to the room or the sender in was takes out nobody
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com, di@example.com"
    When I post to "/rooms/2/settings" the form:
      | name   | Secret |
      | member | 2      |
      | was    | 1      |
      | was    | 2      |
      | was    | 3      |
      | was    | 4      |
      | was    | 99     |
    Then the status is 302
    And the query "select count(*) from memberships where room_id = 2" gives 3
    And the query "select count(*) from memberships where room_id = 2 and user_id in (1, 2, 4)" gives 3

  Scenario: A person who is not active stays in the room, as the form cannot show them
    Given a closed room "Secret" with the members "ana@example.com, di@example.com"
    When I post to "/rooms/2/settings" the form:
      | name | Secret |
    Then the status is 302
    And the query "select count(*) from memberships where room_id = 2 and user_id = 4" gives 1

  Scenario: A refused name shows the form again with what was typed and chosen, and changes nothing
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    When I post to "/rooms/2/settings" the form:
      | name   |   |
      | member | 3 |
      | was    | 2 |
    Then the status is 422
    And the body contains "name=\"was\" type=\"hidden\" value=\"2\""
    And the body contains "Give the room a name of 1 to 100 characters"
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"3\" checked>"
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"2\">"
    And the query "select count(*) from rooms where name = 'Secret'" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id = 2" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id = 3" gives 0

  Scenario: A form that has no name from a member is a 400
    Given a closed room "Secret" with the members "ana@example.com"
    When I post nothing to "/rooms/2/settings"
    Then the status is 400
    When I post to "/rooms/2/settings" the form:
      | name   | Secret |
      | member | abc    |
    Then the status is 400
    When I post to "/rooms/2/settings" the form:
      | name | Secret |
      | was  | abc    |
    Then the status is 400

  Scenario Outline: The settings of a room that the person cannot change answer 404, as a room that was never made does
    Given a closed room "Secret" with the members "bea@example.com"
    And a direct room with the members "bea@example.com, cy@example.com"
    And a direct room with the members "ana@example.com, bea@example.com"
    When I get "<path>"
    Then the status is 404
    And the body is "Not Found"

    Examples:
      | path                                 |
      | /rooms/2/settings                    |
      | /rooms/3/settings                    |
      | /rooms/4/settings                    |
      | /rooms/1/settings                    |
      | /rooms/99/settings                   |
      | /rooms/0/settings                    |
      | /rooms/abc/settings                  |
      | /rooms/99999999999999999999/settings |

  Scenario Outline: A form for the settings of such a room answers 404 before its fields are looked at
    Given a closed room "Secret" with the members "bea@example.com"
    And a direct room with the members "bea@example.com, cy@example.com"
    When I post nothing to "<path>"
    Then the status is 404
    And the body is "Not Found"

    Examples:
      | path                |
      | /rooms/2/settings   |
      | /rooms/3/settings   |
      | /rooms/1/settings   |
      | /rooms/99/settings  |
      | /rooms/abc/settings |

  Scenario: A valid form for a room that the person is not in changes nothing
    Given a closed room "Secret" with the members "bea@example.com"
    When I post to "/rooms/2/settings" the form:
      | name   | Hijacked |
      | member | 1        |
    Then the status is 404
    And the query "select count(*) from rooms where name = 'Secret'" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 1

  Scenario: A page of another site cannot change a room
    Given a closed room "Secret" with the members "ana@example.com"
    And the request header "sec-fetch-site" is "cross-site"
    When I post to "/rooms/2/settings" the form:
      | name   | Hijacked |
      | member | 2        |
    Then the status is 403
    And the query "select count(*) from rooms where name = 'Secret'" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 1

  Scenario Outline: A change that is no longer allowed is refused inside the update, and nothing changes
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And a closed room "Mine" with the members "bea@example.com"
    And a direct room with the members "ana@example.com, bea@example.com"
    When "<editor>" asks Rooms.update_closed to rename the room <room> and swap its members
    Then the update is refused
    And the query "select count(*) from rooms where name in ('All Talk', 'Secret', 'Mine')" gives 3
    And the query "select count(*) from rooms where name = 'Renamed'" gives 0
    And the query "select count(*) from memberships" gives 8

    Examples:
      | room | editor          | why                                             |
      | 2    | bea@example.com | a member who is neither maker nor administrator |
      | 3    | cy@example.com  | a person who is not in the room                 |
      | 3    | ana@example.com | an administrator who is not in the room         |
      | 4    | ana@example.com | a direct room                                   |
      | 1    | ana@example.com | an open room                                    |

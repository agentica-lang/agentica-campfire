Feature: Direct messages
  A direct room is between the person who starts it and the people they pick, and it has no name: each of them sees it
  named after the others. Starting one with exactly the same people as an existing one opens that one. The first admin
  is Ana, user 1, and "All Talk" is room 1; Bea is user 2 and Cy is user 3, so the first room that a scenario makes is
  room 2. Di (user 4) is an inactive person.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And I run the sql "insert into users (name, email, password_digest, active) values ('Di', 'di@example.com', 'x', 0)"

  Scenario: The form of a direct message lists the active people but the person, and the sidebar has the way to it
    When I get "/"
    Then the body contains "<a href=\"/direct_rooms/new\">New direct message</a>"
    When I get "/direct_rooms/new"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/direct_rooms\">"
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"2\">"
    And the body contains "<input type=\"checkbox\" name=\"member\" value=\"3\">"
    And the body does not contain "value=\"1\""
    And the body does not contain "Di"

  Scenario: A direct message with one person is shared by the two, each sees the other's name, and nobody else is in it
    When I post to "/direct_rooms" the form:
      | member | 2 |
    Then the status is 302
    And the header "location" is "/rooms/2"
    And the query "select count(*) from rooms where (id, kind, creator_id) = (2, 'direct', 1) and name is null" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id in (1, 2)" gives 2
    And the query "select count(*) from memberships where room_id = 2" gives 2
    When I get "/"
    Then the body contains "<a href=\"/rooms/2\">Bea</a>"
    When I post to "/rooms/2/messages" the form:
      | body | Hello Bea |
    And I sign in as "bea@example.com"
    And I get "/"
    Then the body contains "<a href=\"/rooms/2\">Ana</a>"
    When I get "/rooms/2"
    Then the status is 200
    And the body contains "<h1>Ana</h1>"
    And the body contains "Hello Bea"
    When I sign in as "cy@example.com"
    And I get "/"
    Then the body does not contain "Bea"
    When I get "/rooms/2"
    Then the status is 404
    And the body is "Not Found"
    When I post to "/rooms/2/messages" the form:
      | body | Let me in |
    Then the status is 404
    And the query "select count(*) from messages where room_id = 2" gives 1

  Scenario: A direct message with several people is named after all the others
    When I post to "/direct_rooms" the form:
      | member | 3 |
      | member | 2 |
    Then the status is 302
    And the header "location" is "/rooms/2"
    And the query "select count(*) from memberships where room_id = 2" gives 3
    When I get "/"
    Then the body contains "<a href=\"/rooms/2\">Bea, Cy</a>"
    When I sign in as "cy@example.com"
    And I get "/"
    Then the body contains "<a href=\"/rooms/2\">Ana, Bea</a>"

  Scenario: The same people open the direct message that exists, whoever starts it and in whatever order
    When I post to "/direct_rooms" the form:
      | member | 2 |
    And I post to "/direct_rooms" the form:
      | member | 2 |
    Then the header "location" is "/rooms/2"
    When I sign in as "bea@example.com"
    And I post to "/direct_rooms" the form:
      | member | 1 |
    Then the header "location" is "/rooms/2"
    And the query "select count(*) from rooms where kind = 'direct'" gives 1
    When I post to "/direct_rooms" the form:
      | member | 1 |
      | member | 3 |
    Then the header "location" is "/rooms/3"
    When I sign in as "cy@example.com"
    And I post to "/direct_rooms" the form:
      | member | 2 |
      | member | 1 |
    Then the header "location" is "/rooms/3"
    And the query "select count(*) from rooms where kind = 'direct'" gives 2

  Scenario: Other people, or a room that is not a direct one, do not make a direct message the same
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    When I post to "/direct_rooms" the form:
      | member | 2 |
    Then the header "location" is "/rooms/3"
    When I post to "/direct_rooms" the form:
      | member | 2 |
      | member | 3 |
    Then the header "location" is "/rooms/4"
    And the query "select count(*) from rooms where kind = 'direct'" gives 2

  Scenario: Forms for the same people that arrive together make one direct message
    When I post to "/direct_rooms" 8 times at once the form:
      | member | 2 |
      | member | 3 |
    Then each status is one of "302, 503"
    And at least one status is 302
    And the query "select count(*) from rooms where kind = 'direct'" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 3

  Scenario Outline: A direct message needs at least one other active person
    When I post to "/direct_rooms" the form:
      | member | <member> |
    Then the status is 422
    And the body contains "Choose at least one person"
    And the query "select count(*) from rooms" gives 1

    Examples:
      | member |
      | 1      |
      | 4      |
      | 99     |

  Scenario: A form with no person is refused and one with something that is not a number is a 400
    When I post nothing to "/direct_rooms"
    Then the status is 422
    And the body contains "Choose at least one person"
    When I post to "/direct_rooms" the form:
      | member | abc |
    Then the status is 400
    And the query "select count(*) from rooms" gives 1

  Scenario: A visitor with no session is sent to sign in, and nothing is made
    Given the browser has no cookies
    When I get "/direct_rooms/new"
    Then the status is 302
    And the header "location" is "/session/new"
    When I post to "/direct_rooms" the form:
      | member | 2 |
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from rooms" gives 1

  Scenario: A page of another site cannot start a direct message
    Given the request header "sec-fetch-site" is "cross-site"
    When I post to "/direct_rooms" the form:
      | member | 2 |
    Then the status is 403
    And the query "select count(*) from rooms" gives 1

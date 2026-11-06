Feature: Notification settings of a room
  A person chooses how much a room notifies them, as in Rails Campfire (`Rooms::InvolvementsController`): `mentions`
  (the default), `everything`, `nothing`, and `invisible`, which also takes the room out of their sidebar. There is no
  separate action to leave a room: an invisible room is not listed, but its page is still there for them, as in Rails.
  A direct room offers only `everything` and `nothing`. The first admin is Ana, user 1, and "All Talk" is room 1; Bea is
  user 2 and Cy is user 3, so the first room that a scenario makes is room 2.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists

  Scenario: The room page links to the settings, which show the level and the four choices of a shared room
    When I get "/rooms/1"
    Then the body contains "<a href=\"/rooms/1/involvement\">Notifications</a>"
    When I get "/rooms/1/involvement"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/rooms/1/involvement\">"
    And the body contains "<input name=\"_method\" type=\"hidden\" value=\"put\">"
    And the body contains "<input name=\"involvement\" type=\"radio\" value=\"mentions\" checked>"
    And the body contains "Notifying about @ mentions"
    And the body contains "<input name=\"involvement\" type=\"radio\" value=\"everything\">"
    And the body contains "Notifying about all messages"
    And the body contains "<input name=\"involvement\" type=\"radio\" value=\"nothing\">"
    And the body contains "Notifications are off"
    And the body contains "<input name=\"involvement\" type=\"radio\" value=\"invisible\">"
    And the body contains "Notifications are off and room invisible in sidebar"
    And the body shows "Notifying about @ mentions" before "Notifying about all messages"

  Scenario Outline: Each level is saved for the person, and the page shows it checked
    When I post to "/rooms/1/involvement" the form:
      | _method     | put     |
      | involvement | <level> |
    Then the status is 302
    And the header "location" is "/rooms/1/involvement"
    And the query "select count(*) from memberships where room_id = 1 and user_id = 1 and involvement = '<level>'" gives 1
    And the query "select count(*) from memberships where room_id = 1 and user_id <> 1 and involvement = 'mentions'" gives 2
    When I get "/rooms/1/involvement"
    Then the body contains "value=\"<level>\" checked"

    Examples:
      | level      |
      | everything |
      | nothing    |
      | invisible  |
      | mentions   |

  Scenario: An invisible room leaves the sidebar of the person but stays reachable, and the others keep it
    When I post to "/rooms/1/involvement" the form:
      | _method     | put       |
      | involvement | invisible |
    And I get "/users/me/sidebar"
    Then the body does not contain "All Talk"
    When I get "/rooms/1"
    Then the status is 200
    And the body contains "<h1>All Talk</h1>"
    When I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    Then the body contains "All Talk"
    When I sign in as "ana@example.com"
    And I post to "/rooms/1/involvement" the form:
      | _method     | put      |
      | involvement | mentions |
    And I get "/users/me/sidebar"
    Then the body contains "All Talk"

  Scenario: A real PUT saves the level as the form does
    When I send a PUT to "/rooms/1/involvement" the form:
      | involvement | everything |
    Then the status is 302
    And the query "select count(*) from memberships where room_id = 1 and user_id = 1 and involvement = 'everything'" gives 1

  Scenario: A direct room offers only everything and nothing
    Given a direct room with the members "ana@example.com, bea@example.com"
    When I get "/rooms/2/involvement"
    Then the status is 200
    And the body contains "value=\"everything\""
    And the body contains "value=\"nothing\""
    And the body does not contain "value=\"mentions\""
    And the body does not contain "value=\"invisible\""
    When I post to "/rooms/2/involvement" the form:
      | _method     | put       |
      | involvement | invisible |
    Then the status is 422
    And the body contains "That is not a choice for this room"
    And the query "select count(*) from memberships where room_id = 2 and user_id = 1 and involvement = 'invisible'" gives 0
    When I post to "/rooms/2/involvement" the form:
      | _method     | put     |
      | involvement | nothing |
    Then the status is 302
    And the query "select count(*) from memberships where room_id = 2 and user_id = 1 and involvement = 'nothing'" gives 1

  Scenario Outline: A level that does not exist changes nothing
    When I post to "/rooms/1/involvement" the form:
      | _method     | put     |
      | involvement | <level> |
    Then the status is 422
    And the body contains "value=\"mentions\" checked"
    And the query "select count(*) from memberships where room_id = 1 and involvement = 'mentions'" gives 3

    Examples:
      | level    |
      | loud     |
      | MENTIONS |
      |          |

  Scenario: A save with no field is a 400
    When I post to "/rooms/1/involvement" the form:
      | _method | put |
    Then the status is 400

  Scenario Outline: A room that the person is not in is 404 for the page and the save, and a visitor has no page
    Given a closed room "Secret" with the members "bea@example.com"
    When I sign in as "ana@example.com"
    And I get "<path>"
    Then the status is 404
    And the body is "Not Found"
    When I post to "<path>" the form:
      | _method     | put        |
      | involvement | everything |
    Then the status is 404
    And the query "select count(*) from memberships where room_id = 2 and involvement = 'everything'" gives 0

    Examples:
      | path                   |
      | /rooms/2/involvement   |
      | /rooms/99/involvement  |
      | /rooms/abc/involvement |

  Scenario: A visitor with no session is sent to sign in, whatever the way to save, and saves nothing
    Given the browser has no cookies
    When I get "/rooms/1/involvement"
    Then the status is 302
    And the header "location" is "/session/new"
    When I post to "/rooms/1/involvement" the form:
      | _method     | put        |
      | involvement | everything |
    Then the status is 302
    And the header "location" is "/session/new"
    When I send a PUT to "/rooms/1/involvement" the form:
      | involvement | everything |
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from memberships where involvement = 'everything'" gives 0

  Scenario: A page of another site saves nothing, as a form or as a real PUT
    Given the request header "sec-fetch-site" is "cross-site"
    When I post to "/rooms/1/involvement" the form:
      | _method     | put        |
      | involvement | everything |
    Then the status is 403
    When I send a PUT to "/rooms/1/involvement" the form:
      | involvement | everything |
    Then the status is 403
    And the query "select count(*) from memberships where involvement = 'everything'" gives 0

  Scenario: The method of the form is read in any case, as Rails reads it
    When I post to "/rooms/1/involvement" the form:
      | _method     | PUT        |
      | involvement | everything |
    Then the status is 302
    And the query "select count(*) from memberships where room_id = 1 and user_id = 1 and involvement = 'everything'" gives 1

  Scenario Outline: A post that is not a put is a 405 that lists the methods of the path
    When I post to "/rooms/1/involvement" the form:
      | _method     | <method>   |
      | involvement | everything |
    Then the status is 405
    And the header "allow" is "GET, HEAD, POST, PUT"
    And the query "select count(*) from memberships where involvement = 'everything'" gives 0

    Examples:
      | method |
      | delete |
      | patch  |
      |        |

  Scenario: A real DELETE is a 405 with the same list
    When I send a DELETE to "/rooms/1/involvement"
    Then the status is 405
    And the header "allow" is "GET, HEAD, POST, PUT"

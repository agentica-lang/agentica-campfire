Feature: Deleting a room
  The person who made a room and an account administrator can delete it, whatever its kind, as in Rails Campfire
  (`RoomsController#destroy`, `Room#destroy_later`). The room leaves every sidebar at once: an open room is closed and
  every membership is deleted in one short transaction. A task of the app then deletes the messages one at a time, each
  in its own transaction, and the room. The first admin is Ana, user 1, and "All Talk" is room 1, which she made; Bea is
  user 2 and Cy is user 3, so the first room that a scenario makes is room 2.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists

  Scenario: The settings of a closed room have a button that deletes it, which asks first
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    When I get "/rooms/2/settings"
    Then the body contains "<form method=\"post\" action=\"/rooms/2\""
    And the body contains "confirm('Are you sure you want to delete this room and all messages in it? This can’t be undone.')"
    And the body contains "<input name=\"_method\" type=\"hidden\" value=\"delete\">"
    And the body contains "Delete room"

  Scenario: The maker deletes a closed room, and it is gone for everybody and its messages go after it
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And the room 2 has 5 messages
    When I sign in as "bea@example.com"
    And I get "/rooms/2"
    Then the status is 200
    When I sign in as "ana@example.com"
    And I post to "/rooms/2" the form:
      | _method | delete |
    Then the status is 302
    And the header "location" is "/"
    And the query "select count(*) from memberships where room_id = 2" gives 0
    When I get "/"
    Then the body does not contain "Secret"
    When I get "/rooms/2"
    Then the status is 404
    When I sign in as "bea@example.com"
    And I get "/rooms/2"
    Then the status is 404
    And the body is "Not Found"
    And the query "select count(*) from rooms where id = 2" gives 0 within 5000 milliseconds
    And the query "select count(*) from messages where room_id = 2" gives 0
    And the query "select count(*) from action_text_rich_texts where record_type = 'Message'" gives 0
    And the query "select count(*) from message_search_index" gives 0
    And the query "select count(*) from rooms" gives 1

  Scenario: An administrator who is in the room but did not make it deletes an open room
    Given I run the sql "update users set role = 1 where id = 2"
    And I sign in as "bea@example.com"
    When I post to "/rooms/1" the form:
      | _method | delete |
    Then the status is 302
    And the header "location" is "/"
    And the query "select count(*) from memberships where room_id = 1" gives 0
    When I sign in as "cy@example.com"
    And I get "/rooms/1"
    Then the status is 404
    And the query "select count(*) from rooms where id = 1" gives 0 within 5000 milliseconds

  Scenario: Another member cannot delete the room
    Given a closed room "Secret" with the members "bea@example.com, cy@example.com, ana@example.com"
    When I sign in as "cy@example.com"
    And I post to "/rooms/2" the form:
      | _method | delete |
    Then the status is 403
    And the body is "Forbidden"
    When I get "/rooms/2"
    Then the status is 200
    And the query "select count(*) from memberships where room_id = 2" gives 3
    And the query "select count(*) from rooms where id = 2" gives 1

  Scenario: The maker of a direct room deletes it, and it leaves the sidebar of the other person
    Given a direct room with the members "ana@example.com, bea@example.com"
    When I post to "/rooms/2" the form:
      | _method | delete |
    Then the status is 302
    When I sign in as "bea@example.com"
    And I get "/rooms/2"
    Then the status is 404
    And the query "select count(*) from rooms where id = 2" gives 0 within 5000 milliseconds

  Scenario Outline: A room that the person is not in, a form that is not a delete and a visitor change nothing
    Given a closed room "Secret" with the members "bea@example.com"
    When I sign in as "<who>"
    And I post to "<path>" the form:
      | _method | <method> |
    Then the status is <status>
    And the query "select count(*) from rooms where name = 'Secret'" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 1

    Examples:
      | who             | path         | method | status |
      | ana@example.com | /rooms/2     | delete | 404    |
      | ana@example.com | /rooms/99    | delete | 404    |
      | ana@example.com | /rooms/abc   | delete | 404    |
      | bea@example.com | /rooms/1     | delete | 403    |

  Scenario: A visitor with no session and a page of another site delete nothing
    Given the browser has no cookies
    When I post to "/rooms/1" the form:
      | _method | delete |
    Then the status is 302
    And the header "location" is "/session/new"
    Given the request header "sec-fetch-site" is "cross-site"
    When I post to "/rooms/1" the form:
      | _method | delete |
    Then the status is 403
    And the query "select count(*) from memberships where room_id = 1" gives 3

  Scenario: A message posted while the room is deleted goes with the room
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And the room 2 has 3 messages
    When "ana@example.com" asks Rooms to delete the room 2 while a message is posted in between
    Then the query "select count(*) from rooms where id = 2" gives 0
    And the query "select count(*) from messages" gives 0
    And the query "select count(*) from action_text_rich_texts" gives 0
    And the query "select count(*) from message_search_index" gives 0

  Scenario: The messages go one at a time, so another write gets in between
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And the room 2 has 3 messages
    When "ana@example.com" takes the room 2 away and deletes 1 of its messages
    And I post to "/rooms/1/messages" the form:
      | message[body] | Still here |
    Then the status is 302
    And the query "select count(*) from messages where room_id = 2" gives 2
    And the query "select count(*) from messages where room_id = 1" gives 1
    And the query "select count(*) from memberships where room_id = 2" gives 0

  Scenario: A real DELETE deletes the room as the form does
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    When I send a DELETE to "/rooms/2"
    Then the status is 302
    And the header "location" is "/"
    And the query "select count(*) from memberships where room_id = 2" gives 0
    And the query "select count(*) from rooms where id = 2" gives 0 within 5000 milliseconds

  Scenario Outline: A post to the room that is not a delete is a 405 that lists the methods
    Given a closed room "Secret" with the members "ana@example.com"
    When I post to "/rooms/2" the form:
      | _method | <method> |
    Then the status is 405
    And the header "allow" is "GET, HEAD, POST, DELETE"
    And the query "select count(*) from rooms where id = 2" gives 1

    Examples:
      | method |
      | put    |
      | patch  |
      |        |

  Scenario: A real PUT is a 405 with the same list
    Given a closed room "Secret" with the members "ana@example.com"
    When I send a PUT to "/rooms/2"
    Then the status is 405
    And the header "allow" is "GET, HEAD, POST, DELETE"
    And the query "select count(*) from rooms where id = 2" gives 1

  Scenario: A post that arrives after the room was deleted stores nothing
    Given a closed room "Secret" with the members "ana@example.com"
    And I run the sql "delete from memberships where room_id = 2"
    And I run the sql "delete from rooms where id = 2"
    When "ana@example.com" asks Rooms.post to post "too late" in the room 2
    Then the update is refused
    And the query "select count(*) from messages" gives 0

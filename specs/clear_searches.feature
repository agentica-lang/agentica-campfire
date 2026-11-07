Feature: Clear the recent searches, and the way back to the last room
  As in Rails Campfire (`SearchesController#clear`, `@return_to_room`), the search page lists the recent searches of
  the person with a button that clears them all, and links back to the room they were in last (`last_room_visited`: the
  room of the `last_room` cookie when they are in it, else the oldest of their rooms). A clear removes the searches of
  the person who is signed in and of nobody else, and the page that follows is never an older, kept one. The first admin
  is Ana, user 1, in room 1, "All Talk", made oldest; Bea is user 2 and the first room that a scenario makes is room 2.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And I run the sql "update rooms set created_at = '2020-01-01 00:00:00.000000' where id = 1"
    And I run the sql "insert into searches (user_id, query, created_at, updated_at) values (1, 'coffee', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000'), (1, 'tea', '2026-03-01 09:01:00.000000', '2026-03-01 09:01:00.000000'), (2, 'cocoa', '2026-03-01 09:02:00.000000', '2026-03-01 09:02:00.000000')"

  Scenario: The button is on the page of a person who has recent searches, and only theirs
    When I get "/searches"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/searches/clear\"" 1 times
    And the body contains "<input name=\"_method\" type=\"hidden\" value=\"delete\">"
    And the body contains "Clear recent searches"
    When I run the sql "delete from searches where user_id = 1"
    And I get "/searches"
    Then the body does not contain "/searches/clear"
    And the body does not contain "Clear recent searches"

  Scenario: Clearing removes the searches of the person and no one else's, whatever the form names
    When I post to "/searches/clear" the form:
      | _method  | delete |
      | user_id  | 2      |
      | user[id] | 2      |
      | q        | cocoa  |
    Then the status is 302
    And the header "location" is "/searches"
    And the query "select count(*) from searches where user_id = 1" gives 0
    And the query "select count(*) from searches where user_id = 2 and query = 'cocoa'" gives 1
    When I get "/searches"
    Then the body does not contain "<li><a href=\"/searches?q=coffee\">"
    And the body does not contain "Clear recent searches"
    When I sign in as "bea@example.com"
    And I get "/searches"
    Then the body contains "<a href=\"/searches?q=cocoa\">cocoa</a>"

  Scenario: A real DELETE clears too, and clearing nothing is the same redirect
    When I send a DELETE to "/searches/clear"
    Then the status is 302
    And the header "location" is "/searches"
    And the query "select count(*) from searches where user_id = 1" gives 0
    When I send a DELETE to "/searches/clear"
    Then the status is 302
    And the header "location" is "/searches"
    And the query "select count(*) from searches" gives 1

  Scenario: A page that was kept does not show the searches that a clear took away
    When I get "/searches?q=coffee"
    And I get "/searches?q=coffee"
    Then the body contains "<a href=\"/searches?q=tea\">tea</a>"
    When I remember the answer
    And I post to "/searches/clear" the form:
      | _method | delete |
    And I get "/searches?q=coffee"
    Then the status is 200
    And the answer is not the one that I remembered
    And the body does not contain "<a href=\"/searches?q=tea\">tea</a>"
    And the body does not contain "Clear recent searches"
    When I post to "/searches" the form:
      | q | tea |
    And I get "/searches?q=coffee"
    Then the body contains "<a href=\"/searches?q=tea\">tea</a>"
    When the app restarts with the page cache off
    And I post to "/searches/clear" the form:
      | _method | delete |
    And I get "/searches"
    Then the body does not contain "<a href=\"/searches?q=tea\">tea</a>"

  Scenario: Any other method is a 405 and nothing is cleared
    When I post to "/searches/clear" the form:
      | _method | patch |
    Then the status is 405
    And the header "allow" is "POST, DELETE"
    When I post to "/searches/clear" the form:
      | q | coffee |
    Then the status is 405
    When I send a PUT to "/searches/clear"
    Then the status is 405
    And the header "allow" is "POST, DELETE"
    When I send a PATCH to "/searches/clear" the form:
      | q | coffee |
    Then the status is 405
    And the header "allow" is "POST, DELETE"
    When I get "/searches/clear"
    Then the status is 405
    And the header "allow" is "POST, DELETE"
    And the query "select count(*) from searches where user_id = 1" gives 2

  Scenario: A visitor is sent to sign in and a page of another site clears nothing
    Given the request header "sec-fetch-site" is "cross-site"
    When I post to "/searches/clear" the form:
      | _method | delete |
    Then the status is 403
    When I send a DELETE to "/searches/clear"
    Then the status is 403
    And the query "select count(*) from searches" gives 3
    Given the request header "sec-fetch-site" is "same-origin"
    And the browser has no cookies
    When I send a DELETE to "/searches/clear"
    Then the status is 302
    And the header "location" is "/session/new"
    When I post to "/searches/clear" the form:
      | _method | delete |
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from searches" gives 3

  Scenario: The page links back to the oldest room, and to the one the person was in last
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    When I get "/searches?q=coffee"
    Then the body contains "<p><a href=\"/rooms/1\">Back to the room</a></p>" 1 times
    When I get "/rooms/2"
    Then the header "set-cookie" contains "last_room=2"
    When I get "/searches?q=coffee"
    Then the body contains "<a href=\"/rooms/2\">Back to the room</a>" 1 times
    And the body does not contain "<a href=\"/rooms/1\">Back to the room</a>"
    When I get "/searches"
    Then the body contains "<a href=\"/rooms/2\">Back to the room</a>"
    When I get "/rooms/1"
    And I get "/searches?q=coffee"
    Then the body contains "<a href=\"/rooms/1\">Back to the room</a>"

  Scenario: A kept page follows the cookie, and a room that the person is not in is the oldest
    Given a closed room "Secret" with the members "ana@example.com"
    And I sign in as "bea@example.com"
    When I get "/searches?q=coffee"
    And I get "/searches?q=coffee"
    Then the body contains "<a href=\"/rooms/1\">Back to the room</a>"
    Given the browser has the cookie "last_room" with the value "2"
    When I get "/searches?q=coffee"
    Then the body contains "<a href=\"/rooms/1\">Back to the room</a>"
    Given the browser has the cookie "last_room" with the value "abc"
    When I get "/searches?q=coffee"
    Then the body contains "<a href=\"/rooms/1\">Back to the room</a>"
    When I run the sql "insert into memberships (room_id, user_id, created_at, updated_at) values (2, 2, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And the browser has the cookie "last_room" with the value "2"
    And I get "/searches?q=coffee"
    Then the body contains "<a href=\"/rooms/2\">Back to the room</a>"
    When I run the sql "delete from memberships where room_id = 2 and user_id = 2"
    And I get "/searches?q=coffee"
    Then the body contains "<a href=\"/rooms/1\">Back to the room</a>"

  Scenario: A person in no room has no link back
    When I run the sql "delete from memberships where user_id = 1"
    And I get "/searches"
    Then the status is 200
    And the body does not contain "Back to the room"

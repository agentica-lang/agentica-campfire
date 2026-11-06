Feature: What the pages need of /cable for their live updates
  The script of the pages (`public/assets/campfire-DIGEST.js`) reads the signed names of the sidebar streams from
  `GET /users/me/sidebar` and the name of the room's stream from the room page, and applies the Turbo Streams it hears.
  These scenarios cover what the server sends and marks for it; the clients are `fixtures/cable_peer.py`, as in
  `cable.feature`. The first admin is Ana, user 1; Bea is user 2 and has "All Talk", room 1, with Ana.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And the cable peer starts

  Scenario: The sidebar marks the rooms that are unread, and the page of a room does not mark its own
    When I post to "/rooms/1/messages" the form:
      | message[body] | Unread for Bea |
    And I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    Then the body contains "<li id=\"room_1\" class=\"unread\"><a href=\"/rooms/1\">All Talk<span class=\"sr-only\"> (unread)</span></a></li>"
    When I get "/rooms/1"
    Then the body contains "<li id=\"room_1\"><a href=\"/rooms/1\">All Talk</a></li>"
    And the body does not contain "class=\"unread\""

  Scenario: A deleted room is shown as gone to the people who look at it, and leaves the sidebar of its people
    When I post to "/closed_rooms" the form:
      | name   | Council |
      | member | 2       |
    And I sign in as "bea@example.com"
    And I get "/rooms/2"
    And I remember the answer
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the streams of the remembered page
    And I get "/users/me/sidebar"
    And client "bea" subscribes to the streams of the last page
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    When I sign in as "ana@example.com"
    And I post to "/rooms/2" the form:
      | _method | delete |
    Then client "bea" eventually receives a frame containing "target=\\\"main\\\"><template><main id=\\\"main\\\"><h1>Council</h1><p role=\\\"status\\\">This room was deleted."
    And client "bea" eventually receives a frame containing "<turbo-stream action=\\\"remove\\\" target=\\\"room_2\\\">"

  Scenario: An open room that is deleted leaves every sidebar, and a person who is not in a closed room hears nothing of its deletion
    When I post to "/rooms" the form:
      | name | Fireside |
    And I post to "/closed_rooms" the form:
      | name | Council |
    And I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the streams of the last page
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    And client "bea" eventually receives a frame containing "confirm_subscription"
    When I sign in as "ana@example.com"
    And I post to "/rooms/3" the form:
      | _method | delete |
    Then client "bea" receives nothing for 500 milliseconds
    When I post to "/rooms/2" the form:
      | _method | delete |
    Then client "bea" eventually receives a frame containing "<turbo-stream action=\\\"remove\\\" target=\\\"room_2\\\">"

  Scenario: A tab that comes back to the page reads the room, and one that leaves does not
    When I sign in as "bea@example.com"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the channel "PresenceChannel" of the room 1
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    When client "bea" performs "absent" in the channel "PresenceChannel" of the room 1
    And 300 milliseconds pass
    And I sign in as "ana@example.com"
    And I post to "/rooms/1/messages" the form:
      | message[body] | While Bea was away |
    And 500 milliseconds pass
    Then the query "select count(*) from memberships where room_id = 1 and user_id = 2 and unread_at is not null" gives 1
    When client "bea" performs "present" in the channel "PresenceChannel" of the room 1
    Then the query "select count(*) from memberships where room_id = 1 and user_id = 2 and unread_at is not null" gives 0 within 2000 milliseconds

  Scenario: An edited message is replaced and a deleted one is removed on the pages that look at the room
    When I get "/rooms/1"
    And client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the streams of the last page
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I post to "/rooms/1/messages" the form:
      | message[body] | First |
    Then client "ana" eventually receives a frame containing "First"
    When I post to "/rooms/1/messages/1" the form:
      | _method      | patch  |
      | message[body] | Second |
    Then client "ana" eventually receives a frame containing "action=\\\"replace\\\" target=\\\"message_1\\\"><template><div id=\\\"message_1\\\""
    When I post to "/rooms/1/messages/1" the form:
      | _method | delete |
    Then client "ana" eventually receives a frame containing "<turbo-stream action=\\\"remove\\\" target=\\\"message_1\\\">"

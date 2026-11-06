Feature: Live updates over /cable
  The app serves the Action Cable WebSocket at `/cable` (bond-channels), the one that the Rails clients and the
  benchmark of basecamp/once-campfire-verification connect to. The pages carry `<turbo-cable-stream-source>` elements
  with signed stream names, and a client subscribes to what they name. The clients here are `fixtures/cable_peer.py`,
  a raw-socket WebSocket client with cookies and an Origin, and every frame is text of `actioncable-v1-json`. The room
  is room 1, "All Talk", and the first admin is Ana, user 1; Bea is user 2.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And the cable peer starts

  Scenario: The room page and the sidebar name their streams with the markup that the benchmark scrapes
    When I get "/rooms/1"
    Then the body contains "<turbo-cable-stream-source channel=\"RoomMessagesChannel\" signed-stream-name=\""
    When I get "/users/me/sidebar"
    Then the body contains "<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"" 2 times

  Scenario: A person who is signed in is welcomed, and anybody else is told not to come back
    When client "ana" connects with the cookies of the browser
    Then the handshake of "ana" is answered 101
    And client "ana" receives:
      """
      {"type":"welcome"}
      """
    When the browser has no cookies
    And client "eve" connects with the cookies of the browser
    Then the handshake of "eve" is answered 101
    And client "eve" receives:
      """
      {"type":"disconnect","reason":"unauthorized","reconnect":false}
      """
    And client "eve" is closed by the server with the code 1000

  Scenario: A message posted over HTTP reaches the people who watch the room, and the post is answered as before
    When client "ana" connects with the cookies of the browser
    And I get "/rooms/1"
    And client "ana" subscribes to the streams of the last page
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Hello cable |
    Then the status is 302
    And the header "location" is "/rooms/1"
    And client "ana" eventually receives a frame containing "Hello cable"
    And the query "select count(*) from messages where room_id = 1" gives 1

  Scenario: A stream of a room that the person is not in is rejected, the stream of another room's page too
    When I post to "/closed_rooms" the form:
      | name | Secret |
    And I get "/rooms/2"
    And I remember the answer
    And I sign in as "bea@example.com"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the streams of the remembered page
    Then client "bea" eventually receives a frame containing "reject_subscription"

  Scenario: The stock Turbo channel refuses the stream of a room's messages
    When I get "/rooms/1"
    And client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the streams of the last page as the channel "Turbo::StreamsChannel"
    Then client "ana" eventually receives a frame containing "reject_subscription"

  Scenario: The sidebar streams are confirmed
    When I get "/users/me/sidebar"
    And client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the streams of the last page
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    And client "ana" eventually receives a frame containing "confirm_subscription"

  Scenario: A message tells the people who have the room unread, and only them, that it has something new
    When I sign in as "bea@example.com"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the channel "UnreadRoomsChannel"
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    When I sign in as "ana@example.com"
    And I post to "/rooms/1/messages" the form:
      | message[body] | News |
    Then client "bea" eventually receives a frame containing "\"message\":{\"at\":\"20"

  Scenario: A person who has the room read and is not connected to it hears no notice
    When client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the channel "UnreadRoomsChannel"
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Mine |
    Then client "ana" receives nothing for 500 milliseconds

  Scenario: The presence of a member reads the room, and a person who is not in the room is rejected
    When I post to "/rooms/1/messages" the form:
      | message[body] | Unread for Bea |
    Then the query "select count(*) from memberships where room_id = 1 and user_id = 2 and unread_at is not null" gives 1
    When I post to "/closed_rooms" the form:
      | name | Secret |
    And I sign in as "bea@example.com"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the channel "PresenceChannel" of the room 2
    Then client "bea" eventually receives a frame containing "reject_subscription"
    When client "bea" subscribes to the channel "PresenceChannel" of the room 1
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    And the query "select count(*) from memberships where room_id = 1 and user_id = 2 and unread_at is not null" gives 0
    When client "bea" performs "refresh" in the channel "PresenceChannel" of the room 1
    Then client "bea" receives nothing for 300 milliseconds

  Scenario: The heartbeat channel only confirms
    When client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the channel "HeartbeatChannel"
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    And client "ana" receives nothing for 300 milliseconds

  Scenario: A room that is made shows up in the sidebars that list it
    When I get "/users/me/sidebar"
    And client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the streams of the last page
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I post to "/rooms" the form:
      | name | Fireside |
    Then client "ana" eventually receives a frame containing "target=\\\"shared_rooms\\\"><template><li id=\\\"room_2\\\"><a href=\\\"/rooms/2\\\">Fireside</a>"

  Scenario: A closed room is told to its people only, and a rename replaces its entry
    When I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the streams of the last page
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    When I sign in as "ana@example.com"
    And I post to "/closed_rooms" the form:
      | name   | Council |
      | member | 2       |
    Then client "bea" eventually receives a frame containing "Council"
    When I post to "/rooms/2/settings" the form:
      | name   | Senate |
      | member | 2      |
      | was    | 2      |
    Then client "bea" eventually receives a frame containing "action=\\\"replace\\\" target=\\\"room_2\\\""

  Scenario: The counts of the hub are for an administrator, and anybody else gets the 404 of any missing path
    When client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the channel "HeartbeatChannel"
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I get "/cable/stats"
    Then the status is 200
    And the body contains "\"connections\":1"
    And the body contains "\"subscriptions\":1"
    And the body contains "\"drops\":0"
    And the body contains "\"lost\":0"
    When I sign in as "bea@example.com"
    And I get "/cable/stats"
    Then the status is 404

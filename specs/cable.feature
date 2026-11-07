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

  Scenario: A boost reaches the people who watch the room as soon as it is added, and so does its removal
    Given I post to "/rooms/1/messages" the form:
      | message[body] | Boost me |
    When client "ana" connects with the cookies of the browser
    And I get "/rooms/1"
    And client "ana" subscribes to the streams of the last page
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I sign in as "bea@example.com"
    And I post to "/messages/1/boosts" the form:
      | boost[content] | 🔥 |
    Then client "ana" eventually receives a frame containing "target=\\\"boosts_message_1\\\"><template><div id=\\\"boost_1\\\""
    When I post to "/messages/1/boosts/1" the form:
      | _method | delete |
    Then client "ana" eventually receives a frame containing "action=\\\"remove\\\" target=\\\"boost_1\\\""

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

  Scenario: A page of another site cannot open the socket, even with the cookies of the person
    When client "evil" connects from the origin "http://evil.example"
    Then the handshake of "evil" is answered 403

  Scenario: A stream name that nobody signed is rejected
    When I get "/rooms/1"
    And client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the streams of the last page with a tampered signature
    Then client "ana" eventually receives a frame containing "reject_subscription"
    And client "ana" receives nothing for 300 milliseconds

  Scenario: A person who is not in a room hears no notice of its messages
    When I post to "/closed_rooms" the form:
      | name | Secret |
    And I sign in as "bea@example.com"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the channel "UnreadRoomsChannel"
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    When I sign in as "ana@example.com"
    And I post to "/rooms/2/messages" the form:
      | message[body] | Not for Bea |
    Then client "bea" receives nothing for 500 milliseconds

  Scenario: A person who is looking at a room has it read when a message comes, until the last tab closes or drops
    When I sign in as "bea@example.com"
    And client "bea1" connects with the cookies of the browser
    And client "bea2" connects with the cookies of the browser
    And client "bea1" subscribes to the channel "PresenceChannel" of the room 1
    And client "bea2" subscribes to the channel "PresenceChannel" of the room 1
    Then client "bea1" eventually receives a frame containing "confirm_subscription"
    And client "bea2" eventually receives a frame containing "confirm_subscription"
    When client "bea1" closes
    And I sign in as "ana@example.com"
    And I post to "/rooms/1/messages" the form:
      | message[body] | One tab is left |
    Then the query "select count(*) from memberships where room_id = 1 and user_id = 2 and unread_at is not null" gives 0 within 2000 milliseconds
    When client "bea2" drops the connection
    And 500 milliseconds pass
    And I post to "/rooms/1/messages" the form:
      | message[body] | Nobody is looking |
    And 500 milliseconds pass
    Then the query "select count(*) from memberships where room_id = 1 and user_id = 2 and unread_at is not null" gives 1

  Scenario: A person who is deactivated is disconnected and told not to come back
    When I sign in as "bea@example.com"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the channel "UnreadRoomsChannel"
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    When I sign in as "ana@example.com"
    And I get "/users"
    And I submit the form of the page that posts to "/users/2/deactivate"
    Then client "bea" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":false}"
    And client "bea" is closed by the server with the code 1000

  Scenario: A person who is banned is disconnected and told not to come back, and the room sees the messages go
    Given I run the sql "insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) values (1, 2, 'm1', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    When I sign in as "bea@example.com"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the channel "UnreadRoomsChannel"
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    When I sign in as "ana@example.com"
    And client "ana" connects with the cookies of the browser
    And I get "/rooms/1"
    And client "ana" subscribes to the streams of the last page
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I post to "/users/2/ban" the form:
      | x | y |
    Then the status is 302
    And client "bea" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":false}"
    And client "bea" is closed by the server with the code 1000
    And client "ana" eventually receives a frame containing "message_"
    And the query "select count(*) from messages where creator_id = 2" gives 0 within 5000 milliseconds

  Scenario: A person who is removed on the account page is disconnected and told not to come back
    When I sign in as "bea@example.com"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the channel "UnreadRoomsChannel"
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    When I sign in as "ana@example.com"
    And I send a DELETE to "/account/users/2"
    Then the status is 302
    And client "bea" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":false}"
    And client "bea" is closed by the server with the code 1000

  Scenario: A removal that is refused leaves the socket open
    When client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the channel "UnreadRoomsChannel"
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I send a DELETE to "/account/users/1"
    Then the status is 403
    When I send a DELETE to "/account/users/99"
    Then the status is 404
    When I sign in as "bea@example.com"
    And I send a DELETE to "/account/users/1"
    Then the status is 403
    And client "ana" receives nothing for 500 milliseconds

  Scenario: A new password ends the sockets of the other sessions of the person, who must sign in again
    When I sign in as "bea@example.com"
    And client "other" connects with the cookies of the browser
    And client "other" subscribes to the channel "UnreadRoomsChannel"
    Then client "other" eventually receives a frame containing "confirm_subscription"
    When I sign in as "bea@example.com"
    And I post to "/users/me/profile" the form:
      | _method                  | patch                 |
      | user[password]           | a brand new password  |
      | user[password_challenge] | another long password |
    Then the status is 302
    And client "other" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}"
    And client "other" is closed by the server with the code 1000

  Scenario: A sign-out ends the sockets of the person, who comes back where another session of theirs is still good
    When client "first" connects with the cookies of the browser
    And the browser saves a copy of its cookies
    And I sign in as "ana@example.com"
    And client "second" connects with the cookies of the browser
    And I post to "/sign_out" the form:
      | x | y |
    Then client "second" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}"
    And client "second" is closed by the server with the code 1000
    And client "first" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}"
    And client "first" is closed by the server with the code 1000
    When client "again" connects with the cookies of the browser
    Then client "again" receives:
      """
      {"type":"disconnect","reason":"unauthorized","reconnect":false}
      """
    When the browser restores its saved cookies
    And client "back" connects with the cookies of the browser
    Then client "back" receives:
      """
      {"type":"welcome"}
      """

  Scenario: A password reset ends the sockets of the person, who is welcomed again with the new session
    When client "old" connects with the cookies of the browser
    And the browser has no cookies
    And I run the sql "insert into password_resets (user_id, token_digest, expires_at) values (1, 'b0d63107a0f0c2528f66e10deb3fcd8590fa25045c5a57cca13f6909a1be5619', strftime('%Y-%m-%d %H:%M:%f000', 'now', '+30 minutes'))"
    And I post to "/password_reset/confirm" the form:
      | token    | resettoken           |
      | password | a brand new password |
    Then the status is 302
    And client "old" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}"
    And client "old" is closed by the server with the code 1000
    When client "new" connects with the cookies of the browser
    Then client "new" receives:
      """
      {"type":"welcome"}
      """

  Scenario: A person who is taken out of a closed room stops hearing it, and is refused when the client comes back
    When I post to "/closed_rooms" the form:
      | name   | Council |
      | member | 2       |
    And I sign in as "bea@example.com"
    And I get "/rooms/2"
    And I remember the answer
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the streams of the remembered page
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    When I sign in as "ana@example.com"
    And I post to "/rooms/2/settings" the form:
      | name | Council |
      | was  | 2       |
    Then client "bea" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}"
    When I sign in as "bea@example.com"
    And client "back" connects with the cookies of the browser
    And client "back" subscribes to the streams of the remembered page
    Then client "back" eventually receives a frame containing "reject_subscription"
    When I get "/rooms/1"
    And client "back" subscribes to the streams of the last page
    Then client "back" eventually receives a frame containing "confirm_subscription"

  Scenario: A socket whose session ended or ran out is closed at the next check
    When I sign in as "bea@example.com"
    And client "bea" connects with the cookies of the browser
    And client "bea" subscribes to the channel "HeartbeatChannel"
    Then client "bea" eventually receives a frame containing "confirm_subscription"
    When client "bea" performs "check" in the channel "HeartbeatChannel"
    Then client "bea" receives nothing for 300 milliseconds
    When I run the sql "update sessions set created_at = strftime('%Y-%m-%d %H:%M:%f', 'now', '-31 days') where user_id = 2"
    And client "bea" performs "check" in the channel "HeartbeatChannel"
    Then client "bea" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}"
    And client "bea" is closed by the server with the code 1000

  Scenario: Stopping the app with a socket open tells the socket to reconnect
    When client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the channel "HeartbeatChannel"
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When the app restarts
    Then client "ana" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":null,\"reconnect\":true}"

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

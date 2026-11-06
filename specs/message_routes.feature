Feature: The message routes of the benchmark
  The room page, the page of older messages and the post of a message have the markup and the answers that the
  benchmark of basecamp/once-campfire-verification checks (its `bench/contracts.rb` and `loadgen/src/validation.rs`): a
  message is a `<div data-message-id="N" id="message_N">` with its text in `<div id="presentation_message_N">` and ends
  with `</turbo-frame></div>`; a post that asks for a Turbo Stream gets one that appends the message to the list of the
  room, `messages_rooms_open_ID` for an open room. A post that does not ask for it (a form without script) is
  redirected to the room page as before. The room is room 1, "All Talk", an open room, and the person is the first
  admin, user 1. The person who may change a message (its author, an administrator) gets one more element in its
  heading, the Edit link of edit_message.feature, and the markup is otherwise this one; the scenarios here are read by
  Ana, who may change every message, so each has the link, in the heading only.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: The room page is a whole document with the markup of its messages
    Given the room 1 has 3 messages
    When I get "/rooms/1"
    Then the status is 200
    And the header "content-type" contains "text/html"
    And the body starts with "<!DOCTYPE html>"
    And the body ends with "</html>"
    And the body contains "<div id=\"message_1\" data-message-id=\"1\">" 1 times
    And the body contains "data-message-id=\"" 3 times
    And the body contains "<div id=\"presentation_message_3\">message 003</div>"
    And the body contains "<turbo-frame id=\"edit_message_3\">"
    And the body contains "id=\"messages_rooms_open_1\"" 1 times
    And the body contains "<link rel=\"stylesheet\" href=\"/assets/" 1 times
    And the body shows "message 001" before "message 003"

  Scenario: The list of a closed room is named after its type
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret" with the members "ana@example.com,bea@example.com"
    When I get "/rooms/2"
    Then the body contains "id=\"messages_rooms_closed_2\"" 1 times

  Scenario: The room page shows the 40 newest messages by time, oldest first
    Given the room 1 has 45 messages
    And I run the sql "update messages set created_at = '2999-01-01 00:00:00.000000' where id = 1"
    When I get "/rooms/1"
    Then the body contains "data-message-id=\"" 40 times
    And the body contains "id=\"presentation_message_" 40 times
    And the body shows "message 045" before "message 001"
    And the body does not contain "message 006"

  Scenario: The page of older messages is a fragment of the 40 before a message
    Given the room 1 has 50 messages
    When I get "/rooms/1/messages?before=46"
    Then the status is 200
    And the header "content-type" contains "text/html"
    And the body does not contain "<html"
    And the body does not contain "<form"
    And the body contains "data-message-id=\"" 40 times
    And the body contains "</turbo-frame></div>" 40 times
    And the body ends with "</turbo-frame></div>"
    And the body contains "<div id=\"presentation_message_6\">message 006</div>"
    And the body does not contain "message 005"
    And the body does not contain "message 046"
    And the body shows "message 006" before "message 045"
    When I get "/rooms/1/messages?before=6"
    Then the body contains "data-message-id=\"" 5 times
    And the body contains "message 001"

  Scenario: Messages are paged by time, so a message that is newer than its id says goes after the cursor
    Given the room 1 has 6 messages
    And I run the sql "update messages set created_at = '2999-01-01 00:00:00.000000' where id = 2"
    When I get "/rooms/1/messages?before=2"
    Then the body contains "data-message-id=\"" 5 times
    And the body does not contain "message 002"
    When I get "/rooms/1/messages?before=1"
    Then the status is 204
    And the body is ""

  Scenario: A cursor that is not a number is refused, and a room that is not the person's is not found
    Given the room 1 has 3 messages
    And a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret" with the members "bea@example.com"
    When I get "/rooms/1/messages?before=abc"
    Then the status is 400
    When I get "/rooms/2/messages?before=2"
    Then the status is 404
    When I get "/rooms/99/messages"
    Then the status is 404
    When I get "/rooms/1/messages"
    Then the body contains "data-message-id=\"" 3 times

  Scenario: A message that a browser posts is answered with a Turbo Stream that appends it to the room
    Given the request header "accept" is "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
    And the request header "sec-fetch-site" is "same-origin"
    When I post to "/rooms/1/messages" the form:
      | message[body]              | bench write 1f2e3d |
      | message[client_message_id] | 17aa5b             |
    Then the status is 200
    And the header "content-type" contains "text/vnd.turbo-stream.html"
    And the body starts with "<turbo-stream"
    And the body ends with "</turbo-stream>"
    And the body contains "action=\"append\""
    And the body contains "target=\"messages_rooms_open_1\""
    And the body contains "<template>" 1 times
    And the body contains "</template>" 1 times
    And the body contains "data-message-id=\"" 1 times
    And the body contains "<div id=\"message_1\" data-message-id=\"1\">" 1 times
    And the body contains "<div id=\"presentation_message_1\">bench write 1f2e3d</div>" 1 times
    And the query "select count(*) from messages where id = 1 and room_id = 1 and creator_id = 1 and client_message_id = '17aa5b'" gives 1
    And the query "select count(*) from action_text_rich_texts where (record_type, record_id, name, body) = ('Message', 1, 'body', 'bench write 1f2e3d')" gives 1
    And the query "select count(*) from message_search_index where rowid = 1 and body = 'bench write 1f2e3d'" gives 1

  Scenario: A Turbo Stream post to a closed room appends to the list that is named after its type
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret" with the members "ana@example.com,bea@example.com"
    And the request header "accept" is "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
    When I post to "/rooms/2/messages" the form:
      | message[body]              | closed write 7c1d |
      | message[client_message_id] | 33be90            |
    Then the status is 200
    And the header "content-type" contains "text/vnd.turbo-stream.html"
    And the body contains "action=\"append\""
    And the body contains "target=\"messages_rooms_closed_2\""
    And the body contains "<div id=\"presentation_message_1\">closed write 7c1d</div>" 1 times
    And the query "select count(*) from messages where id = 1 and room_id = 2 and client_message_id = '33be90'" gives 1

  Scenario: A Turbo Stream post to a room that the person is not in is a 404 and stores nothing
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Theirs" with the members "bea@example.com"
    And the request header "accept" is "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
    When I post to "/rooms/2/messages" the form:
      | message[body]              | sneaky write |
      | message[client_message_id] | 4455aa       |
    Then the status is 404
    And the body is "Not Found"
    And the query "select count(*) from messages" gives 0
    And the query "select count(*) from message_search_index" gives 0

  Scenario: The message that a post answers is written as the room page writes it
    Given the request header "accept" is "text/vnd.turbo-stream.html"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Round & trip <b>bold</b> |
    And I remember the answer
    And I get "/rooms/1"
    Then the body contains the message of the answer that I remembered

  Scenario: The text of a post is shown as text in the Turbo Stream
    Given the request header "accept" is "text/vnd.turbo-stream.html"
    When I post to "/rooms/1/messages" the form:
      | message[body] | <script>alert(1)</script> |
    Then the status is 200
    And the body contains "&lt;script&gt;alert(1)&lt;/script&gt;"
    And the body does not contain "<script>"

  Scenario: A post that does not ask for a Turbo Stream is redirected to the room page
    When I post to "/rooms/1/messages" the form:
      | message[body] | Plain form |
    Then the status is 302
    And the header "location" is "/rooms/1"

  Scenario: A refused post to the Turbo Stream is the page with the reason, and stores nothing
    Given the request header "accept" is "text/vnd.turbo-stream.html"
    When I post to "/rooms/1/messages" the form:
      | message[body] |   |
    Then the status is 422
    And the body contains "Write something to send"
    And the query "select count(*) from messages" gives 0

  Scenario: A post marks the room as changed and the other people as having unread messages
    Given a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And I run the sql "update rooms set updated_at = '2020-01-01 00:00:00.000000' where id = 1"
    And I run the sql "update memberships set involvement = 'invisible' where room_id = 1 and user_id = 3"
    And I run the sql "update memberships set updated_at = '2020-01-01 00:00:00.000000'"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Hello |
    Then the query "select count(*) from rooms where id = 1 and updated_at > '2020-01-02'" gives 1
    And the query "select count(*) from memberships where room_id = 1 and user_id = 2 and unread_at is not null" gives 1
    And the query "select count(*) from memberships where room_id = 1 and user_id = 1 and unread_at is null" gives 1
    And the query "select count(*) from memberships where room_id = 1 and user_id = 3 and unread_at is null" gives 1
    And the query "select count(*) from memberships where updated_at > '2020-01-02'" gives 0
    Given I run the sql "update memberships set connected_at = strftime('%Y-%m-%d %H:%M:%f000', 'now'), unread_at = null where room_id = 1 and user_id = 2"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Hello again |
    Then the query "select count(*) from memberships where room_id = 1 and user_id = 2 and unread_at is null" gives 1

  Scenario: Sixteen people post at once through the default pool and every message is whole
    Given the request header "accept" is "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
    And the request header "sec-fetch-site" is "same-origin"
    When I post 16 messages at once to "/rooms/1/messages"
    Then each status is one of "200"
    And the query "select count(*) from messages where room_id = 1" gives 16
    And the query "select count(*) from action_text_rich_texts where record_type = 'Message' and name = 'body' and body like 'burst %'" gives 16
    And the query "select count(*) from message_search_index where message_search_index match 'burst'" gives 16
    And the query "select count(*) from messages where id not in (select rowid from message_search_index)" gives 0

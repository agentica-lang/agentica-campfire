Feature: Messages
  A room page shows the last 40 messages of the room, the newest at the bottom, with a link to the 40 before them
  (paged by the time of the message, backwards). A message is as Rails keeps it: a row of `messages`, its HTML body in
  `action_text_rich_texts` and its plain text in the search index `message_search_index`, all written together. A form
  on the page posts plain text: it is stored as HTML (escaped, a new line as `<br>`) and shown cleaned, as the HTML that
  Rails stored is. The room is room 1, "All Talk", and the person is the first admin, user 1 (rooms.feature has who may
  see which room).

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: A message is posted in the room and shown with its author
    When I post to "/rooms/1/messages" the form:
      | message[body] | Hello team |
    Then the status is 302
    And the header "location" is "/rooms/1"
    When I get "/rooms/1"
    Then the status is 200
    And the body contains "Hello team"
    And the body contains "Ana"
    And the query "select count(*) from messages where room_id = 1 and creator_id = 1" gives 1
    And the query "select count(*) from action_text_rich_texts where (record_type, record_id, name, body) = ('Message', 1, 'body', 'Hello team')" gives 1
    And the query "select count(*) from message_search_index where rowid = 1 and body = 'Hello team'" gives 1
    And the query "select count(*) from messages where created_at like '____-__-__ __:__:__.______' and updated_at = created_at" gives 1

  Scenario: The time of a message is the clock of an ISO 8601 UTC instant in the page, which datetime keeps whole, whatever the form of the column
    Given a message "Timed" in the room 1 at "2026-03-01 09:00:00.123456"
    When I get "/rooms/1"
    Then the body contains "<time datetime=\"2026-03-01T09:00:00.123Z\" title=\"2026-03-01T09:00:00.123Z\">09:00</time>"

  Scenario: The room page has the form to post, which carries an id for the message
    When I get "/rooms/1"
    Then the body contains "<form method=\"post\" action=\"/rooms/1/messages\">"
    And the body contains "name=\"message[body]\""
    And the body contains "name=\"message[client_message_id]\" type=\"hidden\""

  Scenario: What the form sends is plain text, stored as HTML and escaped in the page
    When I post to "/rooms/1/messages" the form:
      | message[body] | <script>alert(1)</script> & **bold** |
    Then the status is 302
    When I get "/rooms/1"
    Then the body contains "&lt;script&gt;alert(1)&lt;/script&gt; &amp; **bold**"
    And the body does not contain "<script>alert(1)</script>"
    And the query "select count(*) from action_text_rich_texts where body = '&lt;script&gt;alert(1)&lt;/script&gt; &amp; **bold**'" gives 1
    And the query "select count(*) from message_search_index where body = '<script>alert(1)</script> & **bold**'" gives 1

  Scenario: The HTML of a body is cleaned before it is stored, and again when it is shown
    When "ana@example.com" asks Rooms.post to post "<p>Hi <b onclick=\"x()\">there</b><script>alert(1)</script></p>" in the room 1
    Then the query "select count(*) from action_text_rich_texts where body = '<p>Hi <b>there</b></p>'" gives 1
    And the query "select count(*) from message_search_index where body = 'Hi there'" gives 1
    Given I run the sql "insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) values (1, 1, 'rails', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I run the sql "insert into action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at) values ('Message', 2, 'body', '<div>Seen <img src=x onerror=alert(1)><strong>bold</strong></div>', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    When I get "/rooms/1"
    Then the body contains "<p>Hi <b>there</b></p>"
    And the body contains "<div>Seen <strong>bold</strong></div>"
    And the body does not contain "onerror"
    And the body does not contain "onclick"
    And the body does not contain "alert(1)"

  Scenario: A message is found by the stems of its words, and each message has one search row
    When I post to "/rooms/1/messages" the form:
      | message[body] | The fire is burning |
    And I post to "/rooms/1/messages" the form:
      | message[body] | Cold embers |
    Then the query "select count(*) from message_search_index where message_search_index match 'burn'" gives 1
    And the query "select rowid from message_search_index where message_search_index match 'burn'" gives 1
    And the query "select count(*) from message_search_index" gives 2
    And the query "select count(*) from messages where id not in (select rowid from message_search_index)" gives 0

  Scenario: A message that is only spaces is refused
    When I post to "/rooms/1/messages" the form:
      | message[body] |     |
    Then the status is 422
    And the body contains "Write something to send"
    And the query "select count(*) from messages" gives 0
    And the query "select count(*) from action_text_rich_texts" gives 0

  Scenario: A message is at most 10000 characters
    When I post to "/rooms/1/messages" a message of 10000 characters
    Then the status is 302
    When I post to "/rooms/1/messages" a message of 10001 characters
    Then the status is 422
    And the body contains "A message is at most 10000 characters"
    And the query "select count(*) from messages" gives 1

  Scenario: The id of the browser is stored as it came, and a second post with it is a second message
    When I post to "/rooms/1/messages" the form:
      | message[body]              | Twice |
      | message[client_message_id] | c-1   |
    And I post to "/rooms/1/messages" the form:
      | message[body]              | Twice |
      | message[client_message_id] | c-1   |
    Then the status is 302
    And the query "select count(*) from messages where client_message_id = 'c-1'" gives 2

  Scenario: A client message id that is too long is refused
    When I post to "/rooms/1/messages" the form:
      | message[body]              | Hi                                                                    |
      | message[client_message_id] | xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx |
    Then the status is 400
    And the query "select count(*) from messages" gives 0

  Scenario: The messages are shown oldest first, so the newest is at the bottom
    Given the room 1 has 3 messages
    When I get "/rooms/1"
    Then the body shows "message 001" before "message 002"
    And the body shows "message 002" before "message 003"
    And the body does not contain "Older messages"

  Scenario: A room of exactly one page has no link to older messages
    Given the room 1 has 40 messages
    When I get "/rooms/1"
    Then the body contains "message 001"
    And the body contains "message 040"
    And the body does not contain "Older messages"

  Scenario: A longer room shows the last 40 and links to the 40 before them
    Given the room 1 has 45 messages
    When I get "/rooms/1"
    Then the body contains "message 045"
    And the body contains "message 006"
    And the body does not contain "message 005"
    And the body contains "<a href=\"/rooms/1?before=6\">Older messages</a>"
    When I get "/rooms/1?before=6"
    Then the status is 200
    And the body contains "message 001"
    And the body contains "message 005"
    And the body does not contain "message 006"
    And the body does not contain "Older messages"
    And the body contains "<a href=\"/rooms/1\">Latest messages</a>"

  Scenario: A page is the newest 40 by time, not by id, and the cursor is the time of its oldest message
    Given the room 1 has 45 messages
    And I run the sql "update messages set created_at = '2999-01-01 00:00:00.000000' where id = 1"
    When I get "/rooms/1"
    Then the body contains "message 001"
    And the body contains "message 007"
    And the body does not contain "message 006"
    And the body shows "message 045" before "message 001"
    And the body contains "<a href=\"/rooms/1?before=7\">Older messages</a>"
    When I get "/rooms/1?before=1"
    Then the body contains "message 045"
    And the body contains "message 006"
    And the body does not contain "message 005"
    And the body does not contain "message 001"
    When I get "/rooms/1?before=7"
    Then the body contains "message 006"
    And the body does not contain "message 001"
    And the body does not contain "message 007"

  Scenario: Messages with the same time are paged by id, so no page repeats or skips one
    Given the room 1 has 45 messages
    And I run the sql "update messages set created_at = '2026-03-01 09:00:00.000000'"
    When I get "/rooms/1"
    Then the body contains "message 045"
    And the body contains "message 006"
    And the body does not contain "message 005"
    When I get "/rooms/1?before=6"
    Then the body contains "message 005"
    And the body contains "message 001"
    And the body does not contain "message 006"

  Scenario: A message whose author is gone is shown with a placeholder name
    Given an orphan message "Orphan" in the room 1
    When I get "/rooms/1"
    Then the status is 200
    And the body contains "Orphan"
    And the body contains "<strong>Unknown</strong>"

  Scenario: A cursor before the first message shows an empty page, and one that is not a number is a 400
    Given the room 1 has 3 messages
    When I get "/rooms/1?before=1"
    Then the status is 200
    And the body does not contain "message 001"
    When I get "/rooms/1?before=abc"
    Then the status is 400

  Scenario: A message belongs to its room, and a cursor from another room shows nothing of that room
    Given I post to "/rooms" the form:
      | name | Lunch |
    When I post to "/rooms/1/messages" the form:
      | message[body] | In talk |
    And I post to "/rooms/2/messages" the form:
      | message[body] | In lunch |
    And I get "/rooms/1"
    Then the body contains "In talk"
    And the body does not contain "In lunch"
    When I get "/rooms/2"
    Then the body contains "In lunch"
    And the body does not contain "In talk"
    When I get "/rooms/1?before=2"
    Then the status is 200
    And the body does not contain "In talk"
    And the body does not contain "In lunch"
    When I get "/rooms/2?before=2"
    Then the status is 200
    And the body does not contain "In talk"
    And the body does not contain "In lunch"
    When I get "/rooms/2?before=1"
    Then the status is 200
    And the body does not contain "In lunch"

  Scenario: A refused message comes back as a draft that is text, not markup
    When I post to "/rooms/1/messages" a message that starts with "</textarea><script>x</script>" and has 10001 characters
    Then the status is 422
    And the body contains "&lt;/textarea&gt;&lt;script&gt;x&lt;/script&gt;"
    And the body does not contain "<script>x</script>"

  Scenario: A page of another site cannot post a message
    Given the request header "sec-fetch-site" is "cross-site"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Hello |
    Then the status is 403
    And the query "select count(*) from messages" gives 0

  Scenario: A person who was deactivated after the sign-in check cannot post
    Given I run the sql "update users set status = 1 where id = 1"
    When "ana@example.com" asks Rooms.post to post "too late" in the room 1
    Then the update is refused
    And the query "select count(*) from messages" gives 0
    And the query "select count(*) from action_text_rich_texts" gives 0
    And the query "select count(*) from message_search_index" gives 0

  Scenario: A post looks the person up as the sign-in filter does: no session and an ended session are sent to sign in, whatever the form
    Given the browser has no cookies
    When I post to "/rooms/1/messages" the form:
      | message[body] | Hello |
    Then the status is 302
    And the header "location" is "/session/new"
    Given I sign in as "ana@example.com"
    And I run the sql "delete from sessions"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Hello |
    Then the status is 302
    And the header "location" is "/session/new"
    When I post to "/rooms/1/messages" the form:
      | message[client_message_id] | <anything> |
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from messages" gives 0

  Scenario: A post from a signed-in person without a body is a 400
    When I post to "/rooms/1/messages" the form:
      | message[client_message_id] | abc |
    Then the status is 400

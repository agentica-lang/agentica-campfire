Feature: Messages
  A room page shows the last 40 messages of the room, the newest at the bottom, with a link to the 40 before them
  (paged by message id, backwards). A form on the page posts a plain-text message: it is stored as it was sent and
  escaped in the page. The room is room 1, "All Talk", and the person is the first admin, user 1 (rooms.feature has
  who may see which room).

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: A message is posted in the room and shown with its author
    When I post to "/rooms/1/messages" the form:
      | body | Hello team |
    Then the status is 302
    And the header "location" is "/rooms/1"
    When I get "/rooms/1"
    Then the status is 200
    And the body contains "Hello team"
    And the body contains "Ana"
    And the query "select count(*) from messages where room_id = 1 and creator_id = 1 and body = 'Hello team'" gives 1

  Scenario: The room page has the form to post, which carries an id for the message
    When I get "/rooms/1"
    Then the body contains "<form method=\"post\" action=\"/rooms/1/messages\">"
    And the body contains "name=\"body\""
    And the body contains "name=\"client_message_id\" type=\"hidden\""

  Scenario: A message is plain text, stored as sent and escaped in the page
    When I post to "/rooms/1/messages" the form:
      | body | <script>alert(1)</script> & **bold** |
    Then the status is 302
    When I get "/rooms/1"
    Then the body contains "&lt;script&gt;alert(1)&lt;/script&gt; &amp; **bold**"
    And the body does not contain "<script>alert(1)</script>"
    And the query "select count(*) from messages where body = '<script>alert(1)</script> & **bold**'" gives 1

  Scenario: A message that is only spaces is refused
    When I post to "/rooms/1/messages" the form:
      | body |     |
    Then the status is 422
    And the body contains "Write something to send"
    And the query "select count(*) from messages" gives 0

  Scenario: A message is at most 10000 characters
    When I post to "/rooms/1/messages" a message of 10000 characters
    Then the status is 302
    When I post to "/rooms/1/messages" a message of 10001 characters
    Then the status is 422
    And the body contains "A message is at most 10000 characters"
    And the query "select count(*) from messages" gives 1

  Scenario: The same form posted twice stores one message
    When I post to "/rooms/1/messages" the form:
      | body              | Once |
      | client_message_id | c-1  |
    And I post to "/rooms/1/messages" the form:
      | body              | Once |
      | client_message_id | c-1  |
    Then the status is 302
    And the header "location" is "/rooms/1"
    And the query "select count(*) from messages" gives 1

  Scenario: The id that the page writes in its form is the one that the post reads, so posting it twice stores one message
    When I get "/rooms/1"
    And I post to "/rooms/1/messages" twice the form of the page with the body "Once"
    Then the status is 302
    And the header "location" is "/rooms/1"
    And the query "select count(*) from messages where body = 'Once'" gives 1

  Scenario: A client message id that is too long is refused
    When I post to "/rooms/1/messages" the form:
      | body              | Hi                                                                    |
      | client_message_id | xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx |
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
      | body | In talk |
    And I post to "/rooms/2/messages" the form:
      | body | In lunch |
    And I get "/rooms/1"
    Then the body contains "In talk"
    And the body does not contain "In lunch"
    When I get "/rooms/2"
    Then the body contains "In lunch"
    And the body does not contain "In talk"
    When I get "/rooms/1?before=2"
    Then the body contains "In talk"
    And the body does not contain "In lunch"
    When I get "/rooms/2?before=2"
    Then the status is 200
    And the body does not contain "In talk"
    And the body does not contain "In lunch"

  Scenario: A refused message comes back as a draft that is text, not markup
    When I post to "/rooms/1/messages" a message that starts with "</textarea><script>x</script>" and has 10001 characters
    Then the status is 422
    And the body contains "&lt;/textarea&gt;&lt;script&gt;x&lt;/script&gt;"
    And the body does not contain "<script>x</script>"

  Scenario: A page of another site cannot post a message
    Given the request header "sec-fetch-site" is "cross-site"
    When I post to "/rooms/1/messages" the form:
      | body | Hello |
    Then the status is 403
    And the query "select count(*) from messages" gives 0

  Scenario: A person who was deactivated after the sign-in check cannot post
    Given I run the sql "update users set status = 1 where id = 1"
    When "ana@example.com" asks Rooms.post to post "too late" in the room 1
    Then the update is refused
    And the query "select count(*) from messages" gives 0

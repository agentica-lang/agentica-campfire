Feature: Editing and deleting a message
  The person who wrote a message and an account administrator can edit and delete it, as in Rails Campfire
  (`MessagesController#edit`, `#update` and `#destroy`, allowed by `User#can_administer?`). The heading of a message
  has an Edit link for those two people only, and nobody else's markup changes (see message_routes.feature). The edit
  page has the form in the frame `edit_message_ID` and a button that deletes. An edit rewrites the body and the search
  index; a delete removes the body, the index row and the boosts. The first admin is Ana, user 1, and "All Talk" is room
  1; Bea is user 2 and Cy is user 3, and their messages are the ones that Ana, an administrator, may also change.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And I sign in as "bea@example.com"
    And I post to "/rooms/1/messages" the form:
      | message[body] | Coffee at nine |

  Scenario: Only the author and an administrator get the Edit link, and the rest of the message is as before
    When I get "/rooms/1"
    Then the body contains "<a href=\"/rooms/1/messages/1/edit\">Edit</a>" 1 times
    And the body contains "<div id=\"presentation_message_1\">Coffee at nine</div></turbo-frame></div>"
    When I get "/rooms/1/messages"
    Then the body contains "/rooms/1/messages/1/edit" 1 times
    And the body ends with "</turbo-frame></div>"
    When I sign in as "cy@example.com"
    And I get "/rooms/1"
    Then the body does not contain "/edit"
    When I sign in as "ana@example.com"
    And I get "/rooms/1"
    Then the body contains "<a href=\"/rooms/1/messages/1/edit\">Edit</a>" 1 times

  Scenario: The author edits the message, and the page and the search show the new text
    When I get "/rooms/1/messages/1/edit"
    Then the status is 200
    And the body contains "<turbo-frame id=\"edit_message_1\">"
    And the body contains "<form method=\"post\" action=\"/rooms/1/messages/1\">"
    And the body contains "name=\"_method\" type=\"hidden\" value=\"patch\""
    And the body contains ">Coffee at nine</textarea>"
    And the body contains "confirm('Are you sure you want to delete this message?')"
    When I post to "/rooms/1/messages/1" the form:
      | _method       | patch                     |
      | message[body] | Tea at <b>ten</b> & more  |
    Then the status is 302
    And the header "location" is "/rooms/1"
    When I get "/rooms/1"
    Then the body contains "<div id=\"presentation_message_1\">Tea at &lt;b&gt;ten&lt;/b&gt; &amp; more</div>"
    And the body does not contain "Coffee"
    And the query "select count(*) from messages where id = 1 and creator_id = 2" gives 1
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = 'Tea at &lt;b&gt;ten&lt;/b&gt; &amp; more'" gives 1
    And the query "select count(*) from message_search_index where rowid = 1 and body = 'Tea at <b>ten</b> & more'" gives 1
    And the query "select count(*) from message_search_index" gives 1
    When I get "/searches?q=tea"
    Then the body contains "presentation_message_1"
    When I get "/searches?q=coffee"
    Then the body does not contain "presentation_message_1"

  Scenario: An administrator edits a message of somebody else, and a real PATCH does the same
    When I sign in as "ana@example.com"
    And I send a PATCH to "/rooms/1/messages/1" the form:
      | message[body] | Moderated |
    Then the status is 302
    When I get "/rooms/1"
    Then the body contains "<div id=\"presentation_message_1\">Moderated</div>"
    And the query "select count(*) from messages where id = 1 and creator_id = 2" gives 1

  Scenario: A body that is blank or over 10000 characters is refused, and the message stays
    When I post to "/rooms/1/messages/1" the form:
      | _method       | patch |
      | message[body] |       |
    Then the status is 422
    And the body contains "Write something to send"
    When I send a PATCH to "/rooms/1/messages/1" a message of 10001 characters
    Then the status is 422
    And the body contains "A message is at most 10000 characters"
    When I send a PATCH to "/rooms/1/messages/1" a message of 10000 characters
    Then the status is 302
    When I get "/rooms/1/messages/1/edit"
    Then the status is 200

  Scenario: An administrator deletes a message, and the page and the search lose it
    When I sign in as "ana@example.com"
    And I post to "/rooms/1/messages/1" the form:
      | _method | delete |
    Then the status is 302
    And the header "location" is "/rooms/1"
    When I get "/rooms/1"
    Then the body does not contain "Coffee"
    When I get "/searches?q=coffee"
    Then the body does not contain "presentation_message_1"
    And the query "select count(*) from messages" gives 0
    And the query "select count(*) from action_text_rich_texts where record_type = 'Message'" gives 0
    And the query "select count(*) from message_search_index" gives 0

  Scenario: A browser with Turbo asks for a stream, which takes the message off the page, and a boost goes with it
    Given I run the sql "insert into boosts (message_id, booster_id, content, created_at, updated_at) values (1, 3, 'ok', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And the request header "accept" is "text/vnd.turbo-stream.html, text/html"
    When I send a DELETE to "/rooms/1/messages/1"
    Then the status is 200
    And the header "content-type" contains "text/vnd.turbo-stream.html"
    And the body contains "<turbo-stream action=\"remove\" target=\"message_1\">"
    And the query "select count(*) from messages" gives 0
    And the query "select count(*) from boosts" gives 0

  Scenario: Another member cannot see the edit page, edit or delete, and nothing changes
    When I sign in as "cy@example.com"
    And I get "/rooms/1/messages/1/edit"
    Then the status is 403
    And the body is "Forbidden"
    When I post to "/rooms/1/messages/1" the form:
      | _method       | patch   |
      | message[body] | Hijacked |
    Then the status is 403
    When I post nothing to "/rooms/1/messages/1"
    Then the status is 405
    When I post to "/rooms/1/messages/1" the form:
      | _method | delete |
    Then the status is 403
    And the query "select count(*) from messages where id = 1" gives 1
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = 'Coffee at nine'" gives 1

  Scenario Outline: A room, a message or a person that does not fit is a 404, whatever the message says
    Given a closed room "Secret" with the members "ana@example.com"
    And I run the sql "insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) values (2, 1, 'x', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    When I sign in as "bea@example.com"
    And I <step> "<path>"
    Then the status is 404
    And the body is "Not Found"
    And the query "select count(*) from messages" gives 2

    Examples:
      | step        | path                         |
      | get         | /rooms/2/messages/2/edit     |
      | get         | /rooms/1/messages/2/edit     |
      | get         | /rooms/1/messages/99/edit    |
      | get         | /rooms/1/messages/abc/edit   |
      | get         | /rooms/99/messages/1/edit    |
      | send a DELETE to | /rooms/2/messages/2     |
      | send a DELETE to | /rooms/1/messages/2     |
      | send a DELETE to | /rooms/1/messages/99    |
      | send a DELETE to | /rooms/abc/messages/1   |

  Scenario Outline: A visitor with no session and a page of another site change nothing
    Given the browser has no cookies
    When I post to "/rooms/1/messages/1" the form:
      | _method | <method> |
    Then the status is 302
    And the header "location" is "/session/new"
    Given the request header "sec-fetch-site" is "cross-site"
    When I post to "/rooms/1/messages/1" the form:
      | _method       | <method> |
      | message[body] | Hijacked |
    Then the status is 403
    And the query "select count(*) from messages where id = 1" gives 1
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = 'Coffee at nine'" gives 1

    Examples:
      | method |
      | patch  |
      | delete |

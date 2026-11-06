Feature: The cache of whole pages
  The room page and the page of older messages are kept whole (`CAMPFIRE_RESPONSE_CACHE_MB`, 64 by default, 0 for none),
  as Rails Campfire keeps the answer of `rooms#show` and `messages#index`. A page is kept for one person, one room and
  one `?before=`, and for one version of the database: any commit, by anybody, makes the next request build the page
  again. The form of a room page carries a `client_message_id` that is drawn when the page is made, so two answers
  with the same body are one page that was kept, and a page that is made again differs. The room is room 1, "All Talk",
  and the person is the first admin, user 1, "Ana"; Bea is user 2 and Cy is user 3.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And a message "First words" in the room 1 at "2026-03-01 09:00:00.000000"

  Scenario: A page that nothing changed is served again whole, and the same page is made without the cache
    When I get "/rooms/1"
    Then the status is 200
    And the body contains "First words"
    When I remember the answer
    And I remember the messages of the page
    And I get "/rooms/1"
    Then the answer is the one that I remembered
    When the app restarts with the page cache off
    And I get "/rooms/1"
    Then the status is 200
    And the answer is not the one that I remembered
    And the messages of the page are the ones that I remembered

  Scenario: A new message, an edit, a delete and a change of the room or of a person show at once
    When I get "/rooms/1"
    And I remember the answer
    And I post to "/rooms/1/messages" the form:
      | message[body] | Second words |
    And I get "/rooms/1"
    Then the body contains "Second words"
    And the answer is not the one that I remembered
    When I get "/rooms/1"
    And I remember the answer
    And I run the sql "update action_text_rich_texts set body = '<p>Edited words</p>' where record_id = 1"
    And I get "/rooms/1"
    Then the body contains "Edited words"
    And the body does not contain "First words"
    When I run the sql "update rooms set name = 'Fireside' where id = 1"
    And I get "/rooms/1"
    Then the body contains "<h1>Fireside</h1>"
    And the body contains "<li id=\"room_1\"><a href=\"/rooms/1\">Fireside</a></li>"
    When I run the sql "update users set name = 'Anna' where id = 1"
    And I get "/rooms/1"
    Then the body contains "Signed in as Anna"
    When I run the sql "delete from messages where id = 2"
    And I get "/rooms/1"
    Then the body does not contain "Second words"
    And the body contains "Edited words"

  Scenario: Two people never share a page, and a person who is taken out of the room gets the 404 at once
    When I post to "/closed_rooms" the form:
      | name   | Secret |
      | member | 2      |
    And I get "/rooms/2"
    Then the body contains "Signed in as Ana"
    When I get "/rooms/2"
    Then the status is 200
    When I sign in as "bea@example.com"
    And I get "/rooms/2"
    Then the status is 200
    And the body contains "Signed in as Bea"
    And the body does not contain "Signed in as Ana"
    When I sign in as "cy@example.com"
    And I get "/rooms/2"
    Then the status is 404
    And the body is "Not Found"
    When I sign in as "bea@example.com"
    And I get "/rooms/2"
    And I run the sql "delete from memberships where room_id = 2 and user_id = 2"
    And I get "/rooms/2"
    Then the status is 404
    And the body is "Not Found"

  Scenario: A person with the validator gets a 304 until the page changes
    When I get "/rooms/1"
    Then the status is 200
    And the header "etag" contains "W/\""
    And the header "cache-control" is "max-age=0, private, must-revalidate"
    When the request header "if-none-match" is the header "etag" of the answer
    And I get "/rooms/1"
    Then the status is 304
    And the body is ""
    When I post to "/rooms/1/messages" the form:
      | message[body] | News |
    And I get "/rooms/1"
    Then the status is 200
    And the body contains "News"

  Scenario: The older messages are kept for their person, and an edit shows at once
    Given the room 1 has 45 messages
    When I get "/rooms/1/messages?before=45"
    Then the status is 200
    And the header "etag" contains "W/\""
    When I remember the answer
    And I get "/rooms/1/messages?before=45"
    Then the answer is the one that I remembered
    When I run the sql "update action_text_rich_texts set body = '<p>Rewritten</p>' where record_id = 20"
    And I get "/rooms/1/messages?before=45"
    Then the body contains "Rewritten"
    When the request header "if-none-match" is the header "etag" of the answer
    And I get "/rooms/1/messages?before=45"
    Then the status is 304

Feature: The cache of whole pages
  The room page, the page of older messages, the sidebar and the search are kept whole (`CAMPFIRE_RESPONSE_CACHE_MB`,
  64 by default, 0 for none), as Rails Campfire keeps the answer of `rooms#show` and `messages#index`. A page is kept
  for one person, one room and one `?before=` (the sidebar for one person, the search for one query), and for one
  version of the database: any commit, by anybody, makes the next request build the page again. The form of a room page carries a `client_message_id` that is drawn when the page is made, so two answers
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

  Scenario: A new message, a new room, a change of members and an unread mark show in the sidebar and the search at once
    When I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    And I get "/users/me/sidebar"
    Then the status is 200
    And the body contains "<a href=\"/rooms/1\">All Talk</a>"
    And the body does not contain "Fireside"
    And the body does not contain "class=\"unread\""
    When I get "/searches?q=coffee"
    And I get "/searches?q=coffee"
    Then the body does not contain "Coffee time"
    When a message "<p>Coffee time</p>" in the room 1 at "2026-03-01 09:05:00.000000"
    And I get "/searches?q=coffee"
    Then the body contains "<p>Coffee time</p>"
    When I run the sql "update memberships set unread_at = '2026-03-01 09:05:00.000000' where room_id = 1 and user_id = 2"
    And I get "/users/me/sidebar"
    Then the body contains "<li id=\"room_1\" class=\"unread\">"
    When a closed room "Fireside" with the members "ana@example.com,bea@example.com"
    And I get "/users/me/sidebar"
    Then the body contains "<a href=\"/rooms/2\">Fireside</a>"
    When I run the sql "delete from memberships where room_id = 2 and user_id = 2"
    And I get "/users/me/sidebar"
    Then the body does not contain "Fireside"
    When I run the sql "delete from memberships where room_id = 1 and user_id = 2"
    And I get "/searches?q=coffee"
    Then the body does not contain "Coffee time"
    When I get "/searches"
    And I post to "/searches" the form:
      | q | tea |
    And I get "/searches?q=coffee"
    Then the body contains "<a href=\"/searches?q=tea\">tea</a>"

  Scenario: Two people never share a sidebar or a search, and each query has its own page
    Given a closed room "Secret" with the members "ana@example.com"
    And a message "<p>Coffee talk</p>" in the room 2 at "2026-03-01 09:05:00.000000"
    When I get "/users/me/sidebar"
    And I get "/searches?q=coffee"
    And I get "/searches?q=first"
    Then the body contains "First words"
    And the body does not contain "Coffee talk"
    When I get "/searches?q=coffee"
    Then the body contains "Coffee talk"
    When I get "/users/me/sidebar"
    Then the body contains "Secret"
    When I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    Then the body does not contain "Secret"
    And the body contains "Bea"
    When I get "/searches?q=coffee"
    Then the body does not contain "Coffee talk"

  Scenario: A page that is kept has a tag, and the tag gives a 304 until something is committed
    When I get "/users/me/sidebar"
    Then the status is 200
    And the header "etag" contains "W/\""
    When the request header "if-none-match" is the header "etag" of the answer
    And I get "/users/me/sidebar"
    Then the status is 304
    When I run the sql "update rooms set name = 'Fireside' where id = 1"
    And I get "/users/me/sidebar"
    Then the status is 200
    And the body contains "Fireside"
    When I get "/searches?q=first"
    Then the status is 200
    And the header "etag" contains "W/\""
    When the request header "if-none-match" is the header "etag" of the answer
    And I get "/searches?q=first"
    Then the status is 304
    And the body is ""
    When I post to "/rooms/1/messages" the form:
      | message[body] | First of many |
    And I get "/searches?q=first"
    Then the status is 200
    And the body contains "First of many"

  Scenario: A query longer than the form allows is answered with its results and is not kept
    When I get "/searches?q=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    Then the status is 200
    And the body contains "id=\"search_results\"" 1 times
    When a message "<p>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</p>" in the room 1 at "2026-03-01 09:05:00.000000"
    And I get "/searches?q=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    Then the body contains "<p>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</p>"

  Scenario: A person whose session was ended, who was deactivated or who was banned is turned away at once, with their pages kept
    When I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    And I get "/users/me/sidebar"
    And I get "/searches?q=first"
    And I get "/searches?q=first"
    And I get "/rooms/1"
    And I get "/rooms/1"
    Then the status is 200
    When the browser saves a copy of its cookies
    And I post nothing to "/sign_out"
    And the browser restores its saved cookies
    And I get "/users/me/sidebar"
    Then the status is 302
    And the header "location" is "/session/new"
    When I get "/searches?q=first"
    Then the status is 302
    When I get "/rooms/1"
    Then the status is 302
    When I sign in as "cy@example.com"
    And I get "/users/me/sidebar"
    And I get "/searches?q=first"
    And the browser saves a copy of its cookies
    And I run the sql "update users set status = 1 where id = 3"
    And I get "/users/me/sidebar"
    Then the status is 302
    And the header "location" is "/session/new"
    When I get "/searches?q=first"
    Then the status is 302
    When I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    And I get "/users/me/sidebar"
    And the browser saves a copy of its cookies
    And I sign in as "ana@example.com"
    And I post to "/users/2/ban" the form:
      | x | y |
    And the browser restores its saved cookies
    And I get "/users/me/sidebar"
    Then the status is 302
    And the header "location" is "/session/new"
    When I get "/searches?q=first"
    Then the status is 302

  Scenario: A rename shows in the sidebar that was kept
    When I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    And I get "/users/me/sidebar"
    Then the body contains "Signed in as Bea"
    When I run the sql "update users set name = 'Beatrice' where id = 2"
    And I get "/users/me/sidebar"
    Then the body contains "Signed in as Beatrice"

Feature: The messages API of the chat bots
  A chat bot posts, lists, edits and deletes messages with its key in the path (`Messages::ByBotsController` of Rails
  Campfire): `/rooms/ID/KEY/messages` and `/rooms/ID/KEY/messages/ID`, where KEY is `ID-TOKEN`. The body of a post is the
  raw body of the request (HTML, as Action Text takes it, cleaned as every body is), the answers are JSON, and no cookie
  is read: the key is the whole login. A key that names no active bot (a wrong one, an old one after a new token, a
  deactivated bot) and a room that the bot is not in are the same 404, and a bot changes only its own messages (403 for
  the rest). The boosts and the attachments of Rails wait for the features they belong to. The first admin is Ana, user
  1, "All Talk" is room 1 (open) and Bea is user 2. The bot Robo is user 3 (token `aaaaBBBB1111`), made on the bots page
  so that it joins the open rooms. Room 2 is the closed room "Secret" of Ana and Bea.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And I post to "/account/bots" the form:
      | user[name] | Robo |
    And I run the sql "update users set bot_token = 'aaaaBBBB1111' where id = 3"
    And the browser has no cookies

  Scenario: A bot posts and the message shows under its name, to the people of the room and in the search
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Deploy <b>done</b> & green"
    Then the status is 201
    And the header "location" contains "/rooms/1/messages/1"
    And the header "cache-control" is "no-store"
    And the body is ""
    And the query "select count(*) from messages where id = 1 and room_id = 1 and creator_id = 3" gives 1
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = 'Deploy <b>done</b> &amp; green'" gives 1
    And the query "select count(*) from message_search_index where rowid = 1 and body = 'Deploy done & green'" gives 1
    And the query "select count(*) from memberships where room_id = 1 and user_id in (1, 2) and unread_at is not null" gives 2
    And the query "select count(*) from memberships where room_id = 1 and user_id = 3 and unread_at is not null" gives 0
    When I sign in as "bea@example.com"
    And I get "/rooms/1"
    Then the body contains "<strong>Robo</strong>"
    And the body contains "<div id=\"presentation_message_1\">Deploy <b>done</b> &amp; green</div>"
    And the body does not contain "/rooms/1/messages/1/edit"
    When I get "/searches?q=deploy"
    Then the body contains "presentation_message_1"

  Scenario: A body is HTML that is cleaned, and a body with UTF-8 or a new line is kept
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Hi 👋<script>alert(1)</script><img src=x onerror=alert(2)>"
    Then the status is 201
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body like '%👋%' and body not like '%<script%' and body not like '%onerror%'" gives 1

  Scenario: A list whose items have no end tags keeps every item
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" a list of 100 items with no end tags
    Then the status is 201
    And the query "select (length(body) - length(replace(body, '<li>', ''))) / 4 from action_text_rich_texts where record_id = 1" gives 100
    And the query "select (length(body) - length(replace(body, '</li>', ''))) / 5 from action_text_rich_texts where record_id = 1" gives 100

  Scenario: The post is a commit, so the page of the room that was kept is made again, and a new message is announced live
    Given the cable peer starts
    And I sign in as "ana@example.com"
    When I get "/rooms/1"
    And I remember the answer
    And client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the streams of the last page
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Live from Robo"
    Then the status is 201
    And client "ana" eventually receives a frame containing "Live from Robo"
    When I get "/rooms/1"
    Then the body contains "Live from Robo"
    And the answer is not the one that I remembered
    When I send "PATCH" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text "Edited by Robo"
    Then client "ana" eventually receives a frame containing "Edited by Robo"
    When I get "/rooms/1"
    Then the body contains "Edited by Robo"
    And the body does not contain "Live from Robo"
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text ""
    Then client "ana" eventually receives a frame containing "action=\\\"remove\\\" target=\\\"message_1\\\""
    When I get "/rooms/1"
    Then the body does not contain "Edited by Robo"

  Scenario: A body that is blank, too long or a file upload is refused and nothing is posted
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text ""
    Then the status is 422
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "   "
    Then the status is 422
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" a text of 10001 characters
    Then the status is 422
    And the body contains "A message is at most 10000 characters"
    Given the request header "content-type" is "multipart/form-data; boundary=x"
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "--x"
    Then the status is 415
    And the query "select count(*) from messages" gives 0
    Given the request header "content-type" is "text/plain"
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" a text of 10000 characters
    Then the status is 201

  Scenario: The list is the newest 40 messages, oldest first, with the total and a link to the older ones
    Given the room 1 has 100 messages
    When I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages" the text ""
    Then the status is 200
    And the header "content-type" contains "application/json"
    And the header "cache-control" is "no-store"
    And the header "x-total-count" is "100"
    And the header "link" contains "/rooms/1/3-aaaaBBBB1111/messages?before=61>; rel=\"next\""
    And the body shows "\"id\":61," before "\"id\":100,"
    And the body does not contain "\"id\":60,"
    When I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages?before=61" the text ""
    Then the status is 200
    And the header "link" contains "?before=21>; rel=\"next\""
    And the body shows "\"id\":21," before "\"id\":60,"
    And the body does not contain "\"id\":61,"
    When I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages?before=21" the text ""
    Then the status is 200
    And the header "link" is ""
    And the body shows "\"id\":1," before "\"id\":20,"
    And the header "x-total-count" is "100"

  Scenario: The messages after a message are the next 40, with a link while there are more
    Given the room 1 has 100 messages
    When I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages?after=10" the text ""
    Then the status is 200
    And the header "link" contains "?after=50>; rel=\"next\""
    And the body shows "\"id\":11," before "\"id\":50,"
    And the body does not contain "\"id\":10,"
    And the body does not contain "\"id\":51,"
    When I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages?after=60" the text ""
    Then the status is 200
    And the header "link" is ""
    And the body shows "\"id\":61," before "\"id\":100,"
    When I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages?after=100" the text ""
    Then the status is 200
    And the body is "[]"
    And the header "link" is ""

  Scenario Outline: A cursor that is not a message of the room is a 404, and one that is not a number is a 400
    Given the room 1 has 3 messages
    When I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages?<cursor>" the text ""
    Then the status is <status>

    Examples:
      | cursor     | status |
      | before=999 | 404    |
      | after=999  | 404    |
      | before=abc | 400    |
      | after=abc  | 400    |

  Scenario: The list gives each message with its text, its author and its room, and an empty room is an empty list
    Given I sign in as "bea@example.com"
    And I post to "/rooms/1/messages" the form:
      | message[body] | From Bea |
    And the browser has no cookies
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "<p>From <em>Robo</em></p>"
    And I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages" the text ""
    Then the status is 200
    And the header "x-total-count" is "2"
    And the header "link" is ""
    And the body contains "\"creator\":{\"id\":2,\"name\":\"Bea\",\"role\":\"member\"}"
    And the body contains "\"body\":{\"html\":\"<p>From <em>Robo</em></p>\",\"plain_text\":\"From Robo\"}"
    And the body contains "\"creator\":{\"id\":3,\"name\":\"Robo\",\"role\":\"bot\"}"
    And the body contains "\"room\":{\"id\":1}"
    And the body contains "\"url\":\"http://127.0.0.1:"
    And the body contains "/rooms/1/messages/2\""
    And the body shows "From Bea" before "From Robo"
    When I run the sql "delete from messages"
    And I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages" the text ""
    Then the status is 200
    And the body is "[]"
    And the header "x-total-count" is "0"

  Scenario: A bot edits its own message, by PATCH or PUT, and the page and the search show the new text
    Given I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Deploying..."
    When I send "PATCH" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text "Deployed <b>fast</b> 🚀"
    Then the status is 200
    And the header "content-type" contains "application/json"
    And the body contains "\"id\":1,"
    And the body contains "\"plain_text\":\"Deployed fast 🚀\""
    And the body contains "\"creator\":{\"id\":3,\"name\":\"Robo\",\"role\":\"bot\"}"
    And the query "select count(*) from messages" gives 1
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = 'Deployed <b>fast</b> 🚀'" gives 1
    And the query "select count(*) from message_search_index where rowid = 1 and body = 'Deployed fast 🚀'" gives 1
    When I send "PUT" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text "Final"
    Then the status is 200
    And the body contains "\"plain_text\":\"Final\""
    When I sign in as "ana@example.com"
    And I get "/rooms/1"
    Then the body contains "<div id=\"presentation_message_1\">Final</div>"
    When I get "/searches?q=deploying"
    Then the body does not contain "presentation_message_1"

  Scenario: A bot deletes its own message, which takes its body and its search row
    Given I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Oops"
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text ""
    Then the status is 204
    And the body is ""
    And the query "select count(*) from messages" gives 0
    And the query "select count(*) from action_text_rich_texts where record_type = 'Message'" gives 0
    And the query "select count(*) from message_search_index" gives 0
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text ""
    Then the status is 404

  Scenario: A bot cannot change a message of somebody else, not even as the administrator it is not
    Given I sign in as "bea@example.com"
    And I post to "/rooms/1/messages" the form:
      | message[body] | Coffee at nine |
    And the browser has no cookies
    When I send "PATCH" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text "Hijacked"
    Then the status is 403
    When I send "PUT" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text "Hijacked"
    Then the status is 403
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text ""
    Then the status is 403
    And the query "select count(*) from messages where id = 1 and creator_id = 2" gives 1
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = 'Coffee at nine'" gives 1

  Scenario Outline: A message that is not in the room, or has no number, is a 404 before the body is read
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And a message "Hidden" in the room 2 at "2026-03-01 09:00:00.000000"
    When I send "<method>" to "/rooms/1/3-aaaaBBBB1111/messages/<message>" the text "x"
    Then the status is 404
    And the query "select count(*) from action_text_rich_texts where body = 'Hidden'" gives 1

    Examples:
      | method | message |
      | PATCH  | 1       |
      | PATCH  | abc     |
      | DELETE | 1       |
      | DELETE | abc     |

  Scenario: A blank edit is refused and the message stays
    Given I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Keep me"
    When I send "PATCH" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text "  "
    Then the status is 422
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = 'Keep me'" gives 1

  Scenario Outline: A key that names no active bot is a 404 on every route and changes nothing
    Given a message "Ana words" in the room 1 at "2026-03-01 09:00:00.000000"
    When I send "GET" to "/rooms/1/<key>/messages" the text ""
    Then the status is 404
    And the body is "Not Found"
    When I send "POST" to "/rooms/1/<key>/messages" the text "Hello"
    Then the status is 404
    When I send "PATCH" to "/rooms/1/<key>/messages/1" the text "Hello"
    Then the status is 404
    When I send "DELETE" to "/rooms/1/<key>/messages/1" the text ""
    Then the status is 404
    And the query "select count(*) from messages" gives 1
    And the query "select count(*) from action_text_rich_texts where body = 'Ana words'" gives 1

    Examples:
      | key             |
      | 3-wrongTOKEN12  |
      | 3-aaaaBBBB111   |
      | 3-aaaaBBBB11111 |
      | 3-AAAABBBB1111  |
      | 3-              |
      | 3               |
      | -aaaaBBBB1111   |
      | 03-aaaaBBBB1111 |
      | 99-aaaaBBBB1111 |
      | abc-aaaaBBBB1111 |
      | 1-aaaaBBBB1111  |

  Scenario: A new key ends the old one on every route, and the new one works
    Given I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Mine"
    When I sign in as "ana@example.com"
    And I send "PUT" to "/account/bots/3/key" the text ""
    Then the status is 302
    And I run the sql "update users set bot_token = 'ccccDDDD2222' where id = 3"
    When the browser has no cookies
    And I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages" the text ""
    Then the status is 404
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Again"
    Then the status is 404
    When I send "PATCH" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text "Again"
    Then the status is 404
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text ""
    Then the status is 404
    And the query "select count(*) from action_text_rich_texts where body = 'Mine'" gives 1
    When I send "PATCH" to "/rooms/1/3-ccccDDDD2222/messages/1" the text "Renewed"
    Then the status is 200
    And the query "select count(*) from messages where creator_id = 3" gives 1

  Scenario: The key of a deactivated bot is refused on every route, also while its rows are still in the room
    Given I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Mine"
    When I run the sql "update users set status = 1 where id = 3"
    And I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages" the text ""
    Then the status is 404
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Again"
    Then the status is 404
    When I send "PATCH" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text "Again"
    Then the status is 404
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text ""
    Then the status is 404
    And the query "select count(*) from action_text_rich_texts where body = 'Mine'" gives 1

  Scenario: A bot that the administrator removes on the bots page is refused at once
    Given I sign in as "ana@example.com"
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Mine"
    Then the status is 201
    When I send "DELETE" to "/account/bots/3" the text ""
    Then the status is 302
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Again"
    Then the status is 404

  Scenario Outline: A room that the bot is not in, or that does not exist, is a 404 on every route
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And a message "Hidden" in the room 2 at "2026-03-01 09:00:00.000000"
    When I send "GET" to "/rooms/<room>/3-aaaaBBBB1111/messages" the text ""
    Then the status is 404
    And the body is "Not Found"
    When I send "POST" to "/rooms/<room>/3-aaaaBBBB1111/messages" the text "Hello"
    Then the status is 404
    When I send "PATCH" to "/rooms/<room>/3-aaaaBBBB1111/messages/2" the text "Hello"
    Then the status is 404
    When I send "DELETE" to "/rooms/<room>/3-aaaaBBBB1111/messages/2" the text ""
    Then the status is 404
    And the query "select count(*) from messages" gives 1
    And the query "select count(*) from action_text_rich_texts where body = 'Hidden'" gives 1

    Examples:
      | room |
      | 2    |
      | 99   |
      | abc  |

  Scenario: A bot that is put in a closed room can use it
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And I run the sql "insert into memberships (room_id, user_id, created_at, updated_at) values (2, 3, 'now', 'now')"
    When I send "POST" to "/rooms/2/3-aaaaBBBB1111/messages" the text "In secret"
    Then the status is 201
    And the query "select count(*) from messages where room_id = 2 and creator_id = 3" gives 1
    When I send "GET" to "/rooms/2/3-aaaaBBBB1111/messages" the text ""
    Then the body contains "In secret"

  Scenario: The key is the only login: a session does not open the API and the bot has no session
    Given I sign in as "ana@example.com"
    When I send "POST" to "/rooms/1/3-wrongTOKEN12/messages" the text "Posing as Robo"
    Then the status is 404
    When I send "POST" to "/rooms/1/1-whatever/messages" the text "Posing as Ana"
    Then the status is 404
    And the query "select count(*) from messages" gives 0
    When the browser has no cookies
    And I send "POST" to "/rooms/1/messages" the text "x"
    Then the status is 302
    And the header "location" is "/session/new"
    When I get "/rooms/1"
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: A page of another site can call the API with a key, and no browser route is open to it
    Given I sign in as "ana@example.com"
    And the request header "sec-fetch-site" is "cross-site"
    And the request header "origin" is "https://evil.test"
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "From a dashboard"
    Then the status is 201
    When I send "PATCH" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text "Still from a dashboard"
    Then the status is 200
    When I send "POST" to "/rooms/1/3-wrongTOKEN12/messages" the text "x"
    Then the status is 404
    When I send "POST" to "/rooms/1/messages" the text "x"
    Then the status is 403
    When I send "PATCH" to "/rooms/1/messages/1" the text "x"
    Then the status is 403
    When I send "DELETE" to "/rooms/1/messages/1" the text ""
    Then the status is 403
    When I send "POST" to "/rooms/1//messages" the text "x"
    Then the status is 403
    When I send "PATCH" to "/rooms/1/messages/messages" the text "x"
    Then the status is 403
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = 'Still from a dashboard'" gives 1
    And the query "select count(*) from messages" gives 1

  Scenario Outline: A Host that is not a host leaves the links as paths, and the post is stored once
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Hello" with the Host "<host>"
    Then the status is 201
    And the header "location" is "/rooms/1/messages/1"
    And the query "select count(*) from messages" gives 1
    When I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages" the text "" with the Host "<host>"
    Then the status is 200
    And the body contains "\"url\":\"/rooms/1/messages/1\""

    Examples:
      | host           |
      | café.test      |
      | evil.test/x    |
      | evil.test:port |
      | a b            |
      | [::1]x         |

  Scenario Outline: A Host that is a host starts the links, also a service name with an underscore and an IPv6 address
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "Hello" with the Host "<host>"
    Then the status is 201
    And the header "location" is "http://<host>/rooms/1/messages/1"
    When I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages" the text "" with the Host "<host>"
    Then the status is 200
    And the body contains "\"url\":\"http://<host>/rooms/1/messages/1\""

    Examples:
      | host              |
      | campfire_app:3000 |
      | [::1]:80          |
      | 127.0.0.1:3000    |

  Scenario: Another method is a 405 that lists the methods of the path
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages" the text ""
    Then the status is 405
    And the header "allow" is "GET, HEAD, POST"
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages/1" the text "x"
    Then the status is 405

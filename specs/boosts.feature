Feature: Boosts on messages
  A person who is in a room boosts a message of it with one of the eight quick reactions or with words of their own
  (`Messages::BoostsController` of Rails Campfire), and only the booster takes a boost away. A message is reached
  through the membership of its room, so a message of a room the person is not in is a 404, as one that does not
  exist is, and nothing is read from the form before that. A boost shows under its message on the room page, and
  touches the message and the room, so the caches and the refresh see it. The first admin is Ana, user 1; Bea is user
  2 and Cy is user 3. Message 1 is Ana's in "All Talk", the open room 1; message 2 is in the closed room 2, "Secret",
  which Cy is not in.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And a closed room "Secret" with the members "ana@example.com,bea@example.com"
    And I post to "/rooms/1/messages" the form:
      | message[body] | Coffee at nine |
    And I post to "/rooms/2/messages" the form:
      | message[body] | Secret plans |

  Scenario: A member boosts with a reaction and with words, and the room page shows both in the order they came
    When I sign in as "bea@example.com"
    And I get "/messages/1/boosts/new"
    Then the status is 200
    And the body contains "<div id=\"new_boost_message_1\">"
    And the body contains "<form method=\"post\" action=\"/messages/1/boosts\">" 2 times
    And the body contains "class=\"quiet\" name=\"boost[content]\" value=\"" 8 times
    And the body contains "name=\"boost[content]\" value=\"👍\" title=\"Thumbs up\""
    And the body contains "name=\"boost[content]\" value=\"❤️\" title=\"Red heart\""
    And the body contains "maxlength=\"16\""
    And the body contains "<a href=\"/rooms/1/@1\" data-cancel>Back to the room</a>"
    When I post to "/messages/1/boosts" the form:
      | boost[content] | 👍 |
    Then the status is 302
    And the header "location" is "/rooms/1/@1#message_1"
    When I sign in as "cy@example.com"
    And I post to "/messages/1/boosts" the form:
      | boost[content] |   Morning!   |
    Then the status is 302
    When I get "/rooms/1"
    Then the body contains "<div id=\"boosts_message_1\"><div id=\"boost_1\" data-booster-id=\"2\"><small>Bea</small><span>👍</span><form method=\"post\" action=\"/messages/1/boosts/1\">"
    And the body contains "<div id=\"boost_2\" data-booster-id=\"3\"><small>Cy</small><span>Morning!</span>"
    And the body contains "<a href=\"/messages/1/boosts/new\">Boost</a></div></turbo-frame></div>"
    And the body shows "boost_1" before "boost_2"
    And the body shows "boost_2" before "/messages/1/boosts/new"
    And the body contains "<div id=\"boost_" 2 times
    When I get "/messages/1/boosts"
    Then the status is 200
    And the body starts with "<div id=\"boosts_message_1\">"
    And the body contains "<span>Morning!</span>"
    And the query "select count(*) from boosts where message_id = 1 and booster_id = 2 and content = '👍'" gives 1
    And the query "select count(*) from boosts where message_id = 1 and booster_id = 3 and content = 'Morning!'" gives 1

  Scenario: The room page of the booster carries the rule that shows the form that takes a boost away
    When I sign in as "bea@example.com"
    And I post to "/messages/1/boosts" the form:
      | boost[content] | 🔥 |
    And I get "/rooms/1"
    Then the body contains ".thread [data-booster-id=\"2\"]{--boost-remove:grid}"

  Scenario: A boost shows at once through the page cache and the message cache, though nothing touches the message
    When I get "/rooms/1"
    And I get "/rooms/1"
    Then the body does not contain "boost_1"
    When I post to "/messages/1/boosts" the form:
      | boost[content] | 🎉 |
    And I get "/rooms/1"
    Then the body contains "<div id=\"boost_1\" data-booster-id=\"1\"><small>Ana</small><span>🎉</span>"
    When I run the sql "insert into boosts (message_id, booster_id, content, created_at, updated_at) values (1, 2, 'Rails', '2099-01-01 00:00:00.000000', '2099-01-01 00:00:00.000000')"
    And I get "/rooms/1"
    Then the body contains "<span>Rails</span>"
    When I remember the messages of the page
    And the app restarts with the message cache off
    And I get "/rooms/1"
    Then the messages of the page are the ones that I remembered
    When I run the sql "update boosts set content = 'Edited' where id = 2"
    And I get "/rooms/1"
    Then the body contains "<span>Edited</span>"
    And the body does not contain "<span>Rails</span>"
    When I run the sql "delete from boosts"
    And I get "/rooms/1"
    Then the body does not contain "boost_"

  Scenario: A boost touches its message and its room, and the refresh of the room hands the message out again
    Given I run the sql "update messages set created_at = '2019-12-31 00:00:00.000000', updated_at = '2020-01-01 00:00:00.000000'"
    And I run the sql "update rooms set updated_at = '2020-01-01 00:00:00.000000'"
    When I post to "/messages/1/boosts" the form:
      | boost[content] | 👋 |
    Then the query "select count(*) from messages where id = 1 and updated_at > '2020-01-02'" gives 1
    And the query "select count(*) from messages where id = 2 and updated_at < '2020-01-02'" gives 1
    And the query "select count(*) from rooms where id = 1 and updated_at > '2020-01-02'" gives 1
    And the query "select count(*) from rooms where id = 2 and updated_at < '2020-01-02'" gives 1
    When I get "/rooms/1/refresh?since=1577836800000"
    Then the body contains "<turbo-stream action=\"replace\" target=\"message_1\">"
    And the body contains "<span>👋</span>"
    Given I run the sql "update messages set updated_at = '2020-01-01 00:00:00.000000'"
    And I run the sql "update rooms set updated_at = '2020-01-01 00:00:00.000000'"
    When I post to "/messages/1/boosts/1" the form:
      | _method | delete |
    Then the query "select count(*) from messages where id = 1 and updated_at > '2020-01-02'" gives 1
    And the query "select count(*) from rooms where id = 1 and updated_at > '2020-01-02'" gives 1

  Scenario: Only the booster takes a boost away, an administrator and the author of the message included
    Given I sign in as "bea@example.com"
    And I post to "/messages/1/boosts" the form:
      | boost[content] | 👍 |
    And I sign in as "cy@example.com"
    And I post to "/messages/1/boosts" the form:
      | boost[content] | Hello |
    When I post to "/messages/1/boosts/1" the form:
      | _method | delete |
    Then the status is 404
    And the body is "Not Found"
    When I send a DELETE to "/messages/1/boosts/1"
    Then the status is 404
    When I sign in as "ana@example.com"
    And I send a DELETE to "/messages/1/boosts/1"
    Then the status is 404
    When I post to "/messages/1/boosts/2" the form:
      | _method | delete |
    Then the status is 404
    And the query "select count(*) from boosts" gives 2
    When I sign in as "bea@example.com"
    And I post to "/messages/1/boosts/1" the form:
      | _method | Delete |
    Then the status is 302
    And the header "location" is "/rooms/1/@1#message_1"
    And the query "select count(*) from boosts where id = 1" gives 0
    When I send a DELETE to "/messages/1/boosts/2"
    Then the status is 404
    When I send a DELETE to "/messages/1/boosts/1"
    Then the status is 404
    When I sign in as "cy@example.com"
    And I send a DELETE to "/messages/1/boosts/2"
    Then the status is 302
    And the query "select count(*) from boosts" gives 0

  Scenario: A boost of another message is not found through this one
    Given I post to "/messages/2/boosts" the form:
      | boost[content] | 👍 |
    When I send a DELETE to "/messages/1/boosts/1"
    Then the status is 404
    And the query "select count(*) from boosts" gives 1
    When I send a DELETE to "/messages/2/boosts/1"
    Then the status is 302
    And the query "select count(*) from boosts" gives 0

  Scenario: A browser with the script of the page asks for a Turbo Stream and gets the boost to add, and the one to remove
    Given the request header "accept" is "text/vnd.turbo-stream.html, text/html"
    When I post to "/messages/1/boosts" the form:
      | boost[content] | 💪 |
    Then the status is 200
    And the header "content-type" contains "text/vnd.turbo-stream.html"
    And the body starts with "<turbo-stream action=\"append\" target=\"boosts_message_1\"><template><div id=\"boost_1\" data-booster-id=\"1\">"
    And the body ends with "</template></turbo-stream>"
    When I send a DELETE to "/messages/1/boosts/1"
    Then the status is 200
    And the header "content-type" contains "text/vnd.turbo-stream.html"
    And the body is "<turbo-stream action=\"remove\" target=\"boost_1\"><template></template></turbo-stream>"
    And the query "select count(*) from boosts" gives 0

  Scenario: A boost is 1 to 16 characters after the space around it is taken off, and a refusal stores nothing
    When I post to "/messages/1/boosts" the form:
      | boost[content] |       |
    Then the status is 422
    And the body contains "<p role=\"alert\">A boost is 1 to 16 characters</p>"
    And the body contains "<div id=\"new_boost_message_1\">"
    When I post to "/messages/1/boosts" the form:
      | boost[content] | 12345678901234567 |
    Then the status is 422
    And the body contains "value=\"12345678901234567\""
    When I post to "/messages/1/boosts" the form:
      | boost[content] | <b>bold</b> 17 chars |
    Then the status is 422
    And the body contains "value=\"&lt;b&gt;bold&lt;/b&gt; 17 chars\""
    And the query "select count(*) from boosts" gives 0
    When I post to "/messages/1/boosts" the form:
      | boost[content] | 1234567890123456 |
    Then the status is 302
    When I post to "/messages/1/boosts" the form:
      | boost[content] | ❤️ |
    Then the status is 302
    And the query "select count(*) from boosts" gives 2
    When I post nothing to "/messages/1/boosts"
    Then the status is 400
    And the query "select count(*) from boosts" gives 2

  Scenario: Words are shown as text
    When I post to "/messages/1/boosts" the form:
      | boost[content] | <i>"&'x |
    And I get "/rooms/1"
    Then the body contains "<span>&lt;i&gt;&quot;&amp;&#39;x</span>"
    And the body does not contain "<i>"

  Scenario Outline: A person who is not in the room, a message that is not there and a message that is no number are the same 404
    When I sign in as "cy@example.com"
    And I <step> "<path>"
    Then the status is 404
    And the body is "Not Found"
    And the query "select count(*) from boosts" gives 0

    Examples:
      | step                 | path                 |
      | get                  | /messages/2/boosts   |
      | get                  | /messages/2/boosts/new |
      | send a DELETE to     | /messages/2/boosts/1 |
      | get                  | /messages/99/boosts  |
      | get                  | /messages/abc/boosts/new |
      | send a DELETE to     | /messages/99/boosts/1 |
      | send a DELETE to     | /messages/1/boosts/abc |

  Scenario: A post to a message the person cannot reach is a 404 whatever the form says, and stores nothing
    When I sign in as "cy@example.com"
    And I post to "/messages/2/boosts" the form:
      | boost[content] | 👍 |
    Then the status is 404
    When I post to "/messages/2/boosts" the form:
      | boost[content] |   |
    Then the status is 404
    When I post nothing to "/messages/2/boosts"
    Then the status is 404
    When I post to "/messages/99/boosts" the form:
      | boost[content] | 👍 |
    Then the status is 404
    And the query "select count(*) from boosts" gives 0

  Scenario: A person who left a room by being taken out of it, or who was deactivated, stores nothing
    Given I sign in as "bea@example.com"
    And I run the sql "delete from memberships where room_id = 2 and user_id = 2"
    When I post to "/messages/2/boosts" the form:
      | boost[content] | 👍 |
    Then the status is 404
    And the query "select count(*) from boosts" gives 0

  Scenario: The methods of a boost are a post with the method delete and a delete, and any other is a 405
    Given I post to "/messages/1/boosts" the form:
      | boost[content] | 👍 |
    When I post to "/messages/1/boosts/1" the form:
      | _method | put |
    Then the status is 405
    And the header "allow" is "POST, DELETE"
    When I post nothing to "/messages/1/boosts/1"
    Then the status is 405
    When I send a PUT to "/messages/1/boosts/1"
    Then the status is 405
    When I post to "/messages/1/boosts/new" the form:
      | boost[content] | 👍 |
    Then the status is 405
    And the query "select count(*) from boosts" gives 1

  Scenario Outline: A page of another site and a visitor with no session change nothing
    Given I post to "/messages/1/boosts" the form:
      | boost[content] | 👍 |
    And the request header "sec-fetch-site" is "cross-site"
    When I post to "/messages/1/boosts" the form:
      | boost[content] | Forged |
    Then the status is 403
    When I send a DELETE to "/messages/1/boosts/1"
    Then the status is 403
    When I post to "/messages/1/boosts/1" the form:
      | _method | <method> |
    Then the status is 403
    And the query "select count(*) from boosts" gives 1
    Given the browser has no cookies
    And the request header "sec-fetch-site" is "same-origin"
    When I post to "/messages/1/boosts" the form:
      | boost[content] | Anonymous |
    Then the status is 302
    And the header "location" is "/session/new"
    When I post to "/messages/1/boosts/1" the form:
      | _method | <method> |
    Then the status is 302
    And the header "location" is "/session/new"
    When I get "/messages/1/boosts"
    Then the status is 302
    And the header "location" is "/session/new"
    When I get "/messages/1/boosts/new"
    Then the status is 302
    And the query "select count(*) from boosts" gives 1

    Examples:
      | method |
      | delete |
      | Delete |

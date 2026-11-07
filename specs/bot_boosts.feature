Feature: The boosts API of the chat bots
  A chat bot boosts a message of a room it is in and takes its own boost off, with its key in the path
  (`Messages::Boosts::ByBotsController` of Rails Campfire): `POST /rooms/ID/KEY/messages/ID/boosts` with the raw body as
  the text, and `DELETE /rooms/ID/KEY/messages/ID/boosts/ID`. The key is the whole login, as in bot_messages.feature;
  a key that names no active bot, a room the bot is not in and a message that is not in the room are 404, whatever else
  is wrong. A bot boosts any message of the room, and takes off only its own boosts. The first admin is Ana, user 1;
  Bea is user 2; the bot Robo is user 3 (token `aaaaBBBB1111`), in the open room 1. Message 1 is Bea's.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And I post to "/account/bots" the form:
      | user[name] | Robo |
    And I run the sql "update users set bot_token = 'aaaaBBBB1111' where id = 3"
    And I sign in as "bea@example.com"
    And I post to "/rooms/1/messages" the form:
      | message[body] | Coffee at nine |
    And the browser has no cookies

  Scenario: A bot boosts a message and gets the boost, and the people of the room see it under the message
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts" the text "  👀  "
    Then the status is 201
    And the header "content-type" contains "application/json"
    And the header "cache-control" is "no-store"
    And the body contains "\"content\":\"👀\""
    And the body contains "\"booster\":{\"id\":3,\"name\":\"Robo\",\"role\":\"bot\"}"
    And the body contains "/rooms/1/messages/1\"}}"
    And the body contains "\"created_at\":\"20"
    And the query "select count(*) from boosts where id = 1 and message_id = 1 and booster_id = 3 and content = '👀'" gives 1
    When I sign in as "bea@example.com"
    And I get "/rooms/1"
    Then the body contains "<div id=\"boost_1\" data-booster-id=\"3\"><small>Robo</small><span>👀</span>"

  Scenario: The boost of a bot is announced live, and so is its removal
    Given the cable peer starts
    And I sign in as "ana@example.com"
    When I get "/rooms/1"
    And client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the streams of the last page
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts" the text "Nice"
    Then client "ana" eventually receives a frame containing "boosts_message_1"
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts/1" the text ""
    Then the status is 204
    And client "ana" eventually receives a frame containing "target=\\\"boost_1\\\""

  Scenario: A text that is blank, too long or a file upload is refused and nothing is stored
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts" the text "   "
    Then the status is 422
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts" the text "12345678901234567"
    Then the status is 422
    And the query "select count(*) from boosts" gives 0
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts" the text "1234567890123456"
    Then the status is 201

  Scenario: A bot takes off its own boost, and a boost of somebody else is a 404
    Given I run the sql "insert into boosts (message_id, booster_id, content, created_at, updated_at) values (1, 2, 'Mine', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts" the text "Robo's"
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts/1" the text ""
    Then the status is 404
    And the body is "Not Found"
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts/abc" the text ""
    Then the status is 404
    And the query "select count(*) from boosts" gives 2
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts/2" the text ""
    Then the status is 204
    And the body is ""
    And the query "select count(*) from boosts where id = 2" gives 0
    And the query "select count(*) from boosts where id = 1" gives 1

  Scenario Outline: A key that names no active bot, a room it is not in and a message that is not there are 404 on both routes
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And a message "Hidden" in the room 2 at "2026-03-01 09:00:00.000000"
    And I run the sql "insert into boosts (message_id, booster_id, content, created_at, updated_at) values (1, 3, 'Mine', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    When I send "POST" to "<path>/boosts" the text "👀"
    Then the status is 404
    And the body is "Not Found"
    When I send "DELETE" to "<path>/boosts/1" the text ""
    Then the status is 404
    And the query "select count(*) from boosts" gives 1

    Examples:
      | path                                       |
      | /rooms/1/3-wrongTOKEN12/messages/1         |
      | /rooms/1/1-aaaaBBBB1111/messages/1         |
      | /rooms/2/3-aaaaBBBB1111/messages/2         |
      | /rooms/99/3-aaaaBBBB1111/messages/1        |
      | /rooms/1/3-aaaaBBBB1111/messages/2         |
      | /rooms/1/3-aaaaBBBB1111/messages/99        |
      | /rooms/1/3-aaaaBBBB1111/messages/abc       |

  Scenario: A page of another site can call with a key, and the browser routes of boosts stay closed to it
    Given I sign in as "ana@example.com"
    And the request header "sec-fetch-site" is "cross-site"
    And the request header "origin" is "https://evil.test"
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts" the text "From a dashboard"
    Then the status is 201
    When I send "DELETE" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts/1" the text ""
    Then the status is 204
    When I send "POST" to "/messages/1/boosts" the text "x"
    Then the status is 403
    And the query "select count(*) from boosts" gives 0

  Scenario: The key is the only login: a session does not open the boosts API
    Given I sign in as "ana@example.com"
    When I send "POST" to "/rooms/1/1-whatever/messages/1/boosts" the text "Posing as Ana"
    Then the status is 404
    And the query "select count(*) from boosts" gives 0

  Scenario: A bot that was deactivated can no longer boost
    Given I run the sql "update users set status = 1 where id = 3"
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages/1/boosts" the text "Late"
    Then the status is 404
    And the query "select count(*) from boosts" gives 0

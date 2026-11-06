Feature: Messages after a message, around a message, and since a time
  Three more ways to read the messages of a room, as in Rails Campfire. `GET /rooms/ID/messages?after=ID` is the 40
  that come after a message (`MessagesController#find_paged_messages`), as `?before=` is the 40 before it; `before`
  wins when both are given. `GET /rooms/ID/@MESSAGE` is the room page around a message (`page_around`: 40 before it, it,
  and 40 after), and falls back to the newest page when the room has no such message. `GET /rooms/ID/refresh?since=MS`
  (`Rooms::RefreshesController`) is what the live client asks for after it lost its connection: Turbo Streams that
  append the messages created after that time (the first 40, oldest first) and replace each other one that was edited
  after it. All are reads of the room for a member: no session redirects to sign-in, and a room that the person is not
  in is 404, as for any room. The room is room 1, "All Talk", and the person is the first admin, user 1.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: The messages after a message are the next 40, oldest first, as a fragment
    Given the room 1 has 100 messages
    When I get "/rooms/1/messages?after=10"
    Then the status is 200
    And the header "content-type" contains "text/html"
    And the body does not contain "<html"
    And the body contains "data-message-id=\"" 40 times
    And the body ends with "</turbo-frame></div>"
    And the body shows "message 011" before "message 050"
    And the body does not contain "message 010"
    And the body does not contain "message 051"

  Scenario: Nothing after the last message is a 204, and a page with both cursors is the one before
    Given the room 1 has 100 messages
    When I get "/rooms/1/messages?after=100"
    Then the status is 204
    When I get "/rooms/1/messages?before=46&after=10"
    Then the status is 200
    And the body contains "message 006"
    And the body does not contain "message 050"

  Scenario: The messages after a message are the same for the same database, and change with it
    Given the room 1 has 60 messages
    When I get "/rooms/1/messages?after=50"
    And I remember the answer
    And I get "/rooms/1/messages?after=50"
    Then the answer is the one that I remembered
    When I post to "/rooms/1/messages" the form:
      | message[body] | A new one |
    And I get "/rooms/1/messages?after=50"
    Then the answer is not the one that I remembered
    And the body contains "A new one"

  Scenario Outline: A cursor that is not a number is a 400 and one that names no message gives nothing
    Given the room 1 has 3 messages
    When I get "/rooms/1/messages?<cursor>"
    Then the status is <status>

    Examples:
      | cursor     | status |
      | after=abc  | 400    |
      | after=999  | 204    |

  Scenario: The page around a message has the 40 before it, it, and the 40 after
    Given the room 1 has 100 messages
    When I get "/rooms/1/@50"
    Then the status is 200
    And the body starts with "<!DOCTYPE html>"
    And the body contains "data-message-id=\"" 81 times
    And the body shows "message 010" before "message 050"
    And the body shows "message 050" before "message 090"
    And the body does not contain "message 009"
    And the body does not contain "message 091"
    And the body contains "<a href=\"/rooms/1?before=10\">Older messages</a>"
    And the body contains "<a href=\"/rooms/1\">Latest messages</a>"
    And the header "set-cookie" contains "last_room=1"

  Scenario: The page around the first and the last messages has no link in the direction that has nothing
    Given the room 1 has 100 messages
    When I get "/rooms/1/@3"
    Then the body contains "data-message-id=\"" 43 times
    And the body does not contain "Older messages"
    And the body contains "Latest messages"
    When I get "/rooms/1/@95"
    Then the body contains "data-message-id=\"" 46 times
    And the body contains "Older messages"
    And the body does not contain "Latest messages"

  Scenario: A message that the room does not have gives the newest page
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret" with the members "ana@example.com,bea@example.com"
    And the room 1 has 45 messages
    And the room 2 has 1 messages
    When I get "/rooms/1/@999"
    Then the status is 200
    And the body contains "data-message-id=\"" 40 times
    And the body contains "message 045"
    When I get "/rooms/1/@46"
    Then the status is 200
    And the body contains "data-message-id=\"" 40 times
    And the body does not contain "message 001"

  Scenario Outline: A segment that is not an @ and a number, and a room that is not the person's, are 404
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret" with the members "bea@example.com"
    When I get "<path>"
    Then the status is 404
    And the body is "Not Found"

    Examples:
      | path                |
      | /rooms/1/@abc       |
      | /rooms/1/@          |
      | /rooms/1/50         |
      | /rooms/1/nothing    |
      | /rooms/99/@1        |
      | /rooms/abc/@1       |
      | /rooms/2/@1         |
      | /rooms/2/refresh    |
      | /rooms/99/refresh   |
      | /rooms/abc/refresh  |

  Scenario: The messages after a message are not for a person who is not in the room, nor after a message of another room
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret" with the members "bea@example.com"
    And the room 2 has 3 messages
    And the room 1 has 3 messages
    When I get "/rooms/2/messages?after=1"
    Then the status is 404
    And the body is "Not Found"
    When I get "/rooms/1/messages?after=1"
    Then the status is 204

  Scenario: A post to a path under a room that has no post is a 405, not a 404
    When I post nothing to "/rooms/1/nothing"
    Then the status is 405
    And the header "allow" is "GET, HEAD"

  Scenario Outline: A visitor with no session is sent to sign in
    Given the browser has no cookies
    When I get "<path>"
    Then the status is 302
    And the header "location" is "/session/new"

    Examples:
      | path                              |
      | /rooms/1/messages?after=1         |
      | /rooms/1/@1                       |
      | /rooms/1/refresh?since=0          |

  Scenario: The refresh appends the messages created since and replaces the ones edited since
    Given a message "old one" in the room 1 at "2025-06-01 10:00:00.000000"
    And a message "new one" in the room 1 at "2026-06-01 10:00:00.000000"
    And I run the sql "update messages set updated_at = '2026-06-02 10:00:00.000000' where id = 1"
    When I get "/rooms/1/refresh?since=1767225600000"
    Then the status is 200
    And the header "content-type" contains "text/vnd.turbo-stream.html"
    And the body contains "<turbo-stream action=\"append\" target=\"messages_rooms_open_1\">"
    And the body contains "<div id=\"presentation_message_2\">new one</div>"
    And the body contains "<turbo-stream action=\"replace\" target=\"message_1\">"
    And the body contains "<div id=\"presentation_message_1\">old one</div>"
    And the body contains "<turbo-stream action=\"replace\"" 1 times
    And the body contains "<turbo-stream action=\"append\"" 1 times

  Scenario: Nothing since the time is an empty answer, and an edit through the page is a replace
    Given a message "first" in the room 1 at "2025-06-01 10:00:00.000000"
    When I get "/rooms/1/refresh?since=1767225600000"
    Then the status is 200
    And the body is ""
    When I send a PATCH to "/rooms/1/messages/1" the form:
      | message[body] | edited text |
    And I get "/rooms/1/refresh?since=1767225600000"
    Then the body contains "<turbo-stream action=\"replace\" target=\"message_1\">"
    And the body contains "edited text"
    And the body does not contain "action=\"append\""

  Scenario: A message made in the same millisecond as the time is sent again, not skipped
    Given a message "same instant" in the room 1 at "2026-06-01 10:00:00.123000"
    And a message "also this millisecond" in the room 1 at "2026-06-01 10:00:00.123000"
    And a message "before" in the room 1 at "2026-06-01 10:00:00.122000"
    When I get "/rooms/1/refresh?since=1780308000123"
    Then the body contains "same instant"
    And the body contains "also this millisecond"
    And the body does not contain "before"

  Scenario Outline: The time is read as its leading digits, as Ruby's to_i reads it
    Given a message "early" in the room 1 at "1970-01-01 00:00:05.000000"
    And a message "late" in the room 1 at "2026-06-01 10:00:00.000000"
    When I get "/rooms/1/refresh?since=<since>"
    Then the body <late> "late"
    And the body <early> "early"

    Examples:
      | since                | early            | late             |
      | 3000abc              | contains         | contains         |
      | 6000abc              | does not contain | contains         |
      | 1.5e9                | contains         | contains         |
      | 99999999999999999999 | does not contain | does not contain |

  Scenario Outline: No time, a time that is no number, and a time before the epoch are the epoch
    Given the room 1 has 3 messages
    When I get "/rooms/1/refresh<query>"
    Then the status is 200
    And the body contains "data-message-id=\"" 3 times
    And the body contains "<turbo-stream action=\"append\" target=\"messages_rooms_open_1\">"

    Examples:
      | query         |
      |               |
      | ?since=       |
      | ?since=abc    |
      | ?since=-5     |

  Scenario: The refresh appends the first 40 new messages, and the others are replaces that the client ignores
    Given the room 1 has 45 messages
    When I get "/rooms/1/refresh?since=0"
    Then the body contains "data-message-id=\"" 45 times
    And the body contains "<turbo-stream action=\"append\"" 1 times
    And the body contains "<turbo-stream action=\"replace\"" 5 times
    And the body shows "message 001" before "message 040"

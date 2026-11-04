Feature: The sidebar and the search of the benchmark
  `GET /users/me/sidebar` is a whole document with the rooms that the person has not hidden, and `GET /searches?q=`
  one with the messages of their rooms that match the words (the newest 100, oldest first, in the markup of the room
  page), as the benchmark of basecamp/once-campfire-verification checks them. A query is words, never a search
  expression: no query makes the search fail. The person is the first admin, Ana (user 1), in room 1, "All Talk".

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: The sidebar is a whole document with the shared rooms that are not hidden
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret & Co" with the members "ana@example.com,bea@example.com"
    And a closed room "Hidden Room" with the members "ana@example.com,bea@example.com"
    And a direct room with the members "ana@example.com,bea@example.com"
    And I run the sql "update memberships set involvement = 'invisible' where room_id = 3 and user_id = 1"
    When I get "/users/me/sidebar"
    Then the status is 200
    And the header "content-type" contains "text/html"
    And the body starts with "<!DOCTYPE html>"
    And the body ends with "</html>"
    And the body contains "id=\"shared_rooms\"" 1 times
    And the body contains "<a href=\"/rooms/1\">All Talk</a>"
    And the body contains "<a href=\"/rooms/2\">Secret &amp; Co</a>"
    And the body does not contain "Hidden Room"
    And the body contains "<a href=\"/rooms/4\">Bea</a>"
    And the body does not contain "data-message-id"

  Scenario: The sidebar needs a sign-in
    Given the browser has no cookies
    When I get "/users/me/sidebar"
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: The search lists the messages of the rooms of the person that match, oldest first
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Mine" with the members "ana@example.com"
    And a closed room "Theirs" with the members "bea@example.com"
    And a message "<p>Coffee time</p>" in the room 1 at "2026-03-01 09:00:00.000000"
    And a message "<p>Just tea</p>" in the room 1 at "2026-03-01 09:01:00.000000"
    And a message "<p>Many coffees</p>" in the room 2 at "2026-03-01 09:02:00.000000"
    And a message "<p>Secret coffee</p>" in the room 3 at "2026-03-01 09:03:00.000000"
    And a message "<p>More coffee</p>" in the room 1 at "2026-03-01 09:04:00.000000"
    When I get "/searches?q=coffee"
    Then the status is 200
    And the header "content-type" contains "text/html"
    And the body starts with "<!DOCTYPE html>"
    And the body ends with "</html>"
    And the body contains "data-message-id=\"" 3 times
    And the body contains "<div id=\"presentation_message_1\"><p>Coffee time</p></div>"
    And the body contains "<div id=\"presentation_message_3\"><p>Many coffees</p></div>"
    And the body contains "<div id=\"presentation_message_5\"><p>More coffee</p></div>"
    And the body shows "Coffee time" before "Many coffees"
    And the body shows "Many coffees" before "More coffee"
    And the body does not contain "Just tea"
    And the body does not contain "Secret coffee"

  Scenario: The search gives the newest 100 messages
    Given the room 1 has 105 messages
    When I get "/searches?q=message"
    Then the body contains "data-message-id=\"" 100 times
    And the body shows "message 006" before "message 105"
    And the body does not contain "message 005"

  Scenario Outline: A query is words, so syntax of the search is not run and nothing fails
    Given the room 1 has 3 messages
    When I get "/searches?q=<query>"
    Then the status is 200
    And the body contains "id=\"search_results\"" 1 times
    And the body contains "data-message-id=\"" <found> times

    Examples:
      | query           | found |
      | message         | 3     |
      | message+AND     | 0     |
      | AND             | 0     |
      | message+OR+tea  | 0     |
      | NEAR%28message  | 0     |
      | %22             | 0     |
      | message%22      | 3     |
      | mes%2A          | 0     |
      | message+-tea    | 0     |
      | body%3Amessage  | 0     |
      | %21%21          | 0     |
      | +               | 0     |
      | %E2%80%94       | 0     |
      | message+%E2%80%94+message | 3 |
      | message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+message+zzz | 3 |

  Scenario: A query that is shown is shown as text
    When I get "/searches?q=%3Cscript%3Ealert%281%29%3C%2Fscript%3E"
    Then the status is 200
    And the body does not contain "<script>"

  Scenario: Posting a search remembers it, once, among the ten last, and a get does not
    When I get "/searches?q=coffee"
    Then the query "select count(*) from searches" gives 0
    When I post to "/searches" the form:
      | q | coffee, & tea! |
    Then the status is 302
    And the header "location" is "/searches?q=coffee+tea"
    And the query "select count(*) from searches where user_id = 1 and query = 'coffee tea'" gives 1
    When I post to "/searches" the form:
      | q | coffee, & tea! |
    Then the query "select count(*) from searches" gives 1
    When I get "/searches"
    Then the body contains "href=\"/searches?q=coffee+tea\""
    When I post to "/searches" the form:
      | q | one |
    And I post to "/searches" the form:
      | q | two |
    And I post to "/searches" the form:
      | q | three |
    And I post to "/searches" the form:
      | q | four |
    And I post to "/searches" the form:
      | q | five |
    And I post to "/searches" the form:
      | q | six |
    And I post to "/searches" the form:
      | q | seven |
    And I post to "/searches" the form:
      | q | eight |
    And I post to "/searches" the form:
      | q | nine |
    And I post to "/searches" the form:
      | q | ten |
    And I post to "/searches" the form:
      | q | eleven |
    Then the query "select count(*) from searches where user_id = 1" gives 10
    And the query "select count(*) from searches where query = 'coffee tea'" gives 0
    When I post to "/searches" the form:
      | q | ! |
    Then the status is 302
    And the header "location" is "/searches"
    And the query "select count(*) from searches where user_id = 1" gives 10

Feature: Home goes to the last room visited
  As in Rails Campfire (`WelcomeController#show`, `TrackedRoomVisit`), the home page of a person who is in a room sends
  them to the room they were in last, which a permanent cookie, `last_room`, remembers: a room page that is served sets
  it. With no cookie, or a cookie that names a room the person is not in (they left it, or it is not theirs, or it is no
  room), it is the oldest room they are in. A person in no room gets the welcome page. Nothing here writes: the cookie
  only chooses among the rooms of the person, who is checked through their memberships each time. The first admin is
  Ana, user 1; "All Talk" is room 1, made oldest; Bea is user 2, and the first room that a scenario makes is room 2.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And I run the sql "update rooms set created_at = '2020-01-01 00:00:00.000000' where id = 1"

  Scenario: With no cookie the home page opens the oldest room
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    When I get "/"
    Then the status is 302
    And the header "location" is "/rooms/1"

  Scenario: A room page sets the cookie, and the home page opens that room
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    When I get "/rooms/2"
    Then the status is 200
    And the header "set-cookie" contains "last_room=2"
    And the header "set-cookie" contains "Max-Age=630720000"
    And the header "set-cookie" contains "Path=/"
    When I get "/"
    Then the status is 302
    And the header "location" is "/rooms/2"
    When I get "/rooms/2"
    Then the header "set-cookie" does not contain "last_room"
    When I get "/rooms/1"
    Then the header "set-cookie" contains "last_room=1"
    When I get "/rooms/2"
    Then the header "set-cookie" contains "last_room=2"
    When I get "/"
    Then the header "location" is "/rooms/2"

  Scenario: A room that is not found sets no cookie, and the older messages are not a visit
    Given a closed room "Secret" with the members "ana@example.com"
    And I sign in as "bea@example.com"
    When I get "/rooms/2"
    Then the status is 404
    And the header "set-cookie" does not contain "last_room"
    When I get "/rooms/99"
    Then the header "set-cookie" does not contain "last_room"
    When I get "/rooms/1/messages"
    Then the header "set-cookie" does not contain "last_room"

  Scenario Outline: A cookie for a room the person is not in, or that is no room, falls back to the oldest
    Given a closed room "Secret" with the members "ana@example.com"
    And I sign in as "bea@example.com"
    And the browser has the cookie "last_room" with the value "<value>"
    When I get "/"
    Then the status is 302
    And the header "location" is "/rooms/1"

    Examples:
      | value                |
      | 2                    |
      | 99                   |
      | abc                  |
      | 99999999999999999999 |

  Scenario: A room that the person left falls back to the oldest
    Given a closed room "Secret" with the members "ana@example.com, bea@example.com"
    And I sign in as "bea@example.com"
    When I get "/rooms/2"
    Then the header "set-cookie" contains "last_room=2"
    When I get "/"
    Then the header "location" is "/rooms/2"
    When I run the sql "delete from memberships where room_id = 2 and user_id = 2"
    And I get "/"
    Then the header "location" is "/rooms/1"

  Scenario: The oldest room is the oldest by time among the rooms of the person, not by id
    Given a closed room "Secret" with the members "bea@example.com"
    And I run the sql "delete from memberships where room_id = 1 and user_id = 2"
    And I run the sql "update rooms set created_at = '2019-01-01 00:00:00.000000' where id = 2"
    And I sign in as "bea@example.com"
    When I get "/"
    Then the header "location" is "/rooms/2"

  Scenario: A person in no room gets the welcome page, and a visitor is sent to sign in
    Given I run the sql "delete from memberships where user_id = 2"
    And I sign in as "bea@example.com"
    When I get "/"
    Then the status is 200
    And the body contains "<h1>Campfire</h1>"
    And the body contains "Signed in as Bea"
    Given the browser has no cookies
    When I get "/"
    Then the status is 302
    And the header "location" is "/session/new"

Feature: Rooms
  A room is open (every person on the account is a member), closed (only the people on its member list) or direct
  (between people). A person sees the rooms that they are a member of, and nothing tells them that another one exists:
  a room that they are not in answers 404, the same as a room that was never made. This feature makes open rooms;
  closed_rooms.feature and direct_rooms.feature make the other kinds through their pages, and the closed and direct
  rooms of the scenarios here are made by steps. The first admin is user 1 and "All Talk", which the first run makes,
  is room 1; the next room is 2.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: The first run makes an open room with the administrator in it
    When I get "/"
    Then the status is 200
    And the body contains "<a href=\"/rooms/1\">All Talk</a>"
    And the query "select count(*) from rooms where (id, type, name, creator_id) = (1, 'Rooms::Open', 'All Talk', 1)" gives 1
    And the query "select count(*) from memberships where room_id = 1 and user_id = 1" gives 1

  Scenario: Any member makes an open room, not only an administrator
    Given a member "Bea" with the email "bea@example.com" exists
    And I sign in as "bea@example.com"
    When I get "/rooms/new"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/rooms\">"
    And the body contains "name=\"name\""
    When I post to "/rooms" the form:
      | name | Lunch |
    Then the status is 302
    And the header "location" is "/rooms/2"
    When I get "/rooms/2"
    Then the status is 200
    And the body contains "<title>Lunch</title>"
    And the body contains "<h1>Lunch</h1>"
    And the query "select count(*) from rooms where id = 2 and type = 'Rooms::Open' and creator_id = 2" gives 1

  Scenario: An open room puts every active person in it, and nobody else
    Given a member "Bea" with the email "bea@example.com" exists
    And a user "Cy" with the email "cy@example.com", the role "member" and the status "deactivated" exists
    When I post to "/rooms" the form:
      | name | Lunch |
    Then the status is 302
    And the query "select count(*) from memberships where room_id = 2" gives 2
    And the query "select count(*) from memberships where room_id = 2 and user_id = 3" gives 0
    When I sign in as "bea@example.com"
    And I get "/"
    Then the body contains "<a href=\"/rooms/1\">All Talk</a>"
    And the body contains "<a href=\"/rooms/2\">Lunch</a>"

  Scenario Outline: A room needs a name of 1 to 100 characters
    When I post to "/rooms" the form:
      | name | <name> |
    Then the status is 422
    And the body contains "Give the room a name of 1 to 100 characters"
    And the query "select count(*) from rooms" gives 1

    Examples:
      | name                                                                                                  |
      |                                                                                                       |
      | xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx |

  Scenario: The name of a room is text, in the page and in the sidebar
    When I post to "/rooms" the form:
      | name | <b>Lunch</b> |
    Then the status is 302
    When I get "/rooms/2"
    Then the body contains "<h1>&lt;b&gt;Lunch&lt;/b&gt;</h1>"
    And the body contains "<a href=\"/rooms/2\">&lt;b&gt;Lunch&lt;/b&gt;</a>"
    And the body does not contain "<b>Lunch</b>"

  Scenario: The sidebar lists the rooms of the person, and the direct messages by the other people
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret" with the members "bea@example.com"
    And a direct room with the members "ana@example.com, bea@example.com"
    When I get "/"
    Then the body contains "<a href=\"/rooms/1\">All Talk</a>"
    And the body contains "<a href=\"/rooms/3\">Bea</a>"
    And the body does not contain "Secret"
    When I sign in as "bea@example.com"
    And I get "/"
    Then the body contains "<a href=\"/rooms/1\">All Talk</a>"
    And the body contains "<a href=\"/rooms/2\">Secret</a>"
    And the body contains "<a href=\"/rooms/3\">Ana</a>"

  Scenario: A room that the person set to invisible is out of the sidebar, and still there for whoever has the address
    Given I run the sql "update memberships set involvement = 'invisible' where room_id = 1 and user_id = 1"
    When I get "/"
    Then the body does not contain "All Talk"
    When I get "/rooms/1"
    Then the status is 200

  Scenario: A member of a closed room and of a direct room reads and posts there
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret" with the members "bea@example.com"
    And a direct room with the members "bea@example.com, ana@example.com"
    And I sign in as "bea@example.com"
    When I get "/rooms/2"
    Then the status is 200
    And the body contains "<h1>Secret</h1>"
    When I post to "/rooms/2/messages" the form:
      | body | Hi Secret |
    Then the status is 302
    When I get "/rooms/2"
    Then the body contains "Hi Secret"
    When I get "/rooms/3"
    Then the status is 200
    And the body contains "<h1>Ana</h1>"
    When I post to "/rooms/3/messages" the form:
      | body | Hi Ana |
    Then the status is 302
    When I get "/rooms/3"
    Then the body contains "Hi Ana"

  Scenario Outline: A room that the person is not in answers 404, as a room that was never made does
    Given a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And a closed room "Secret" with the members "bea@example.com"
    And a direct room with the members "bea@example.com, cy@example.com"
    When I get "<path>"
    Then the status is 404
    And the body is "Not Found"

    Examples:
      | path                        |
      | /rooms/2                    |
      | /rooms/3                    |
      | /rooms/99                   |
      | /rooms/0                    |
      | /rooms/abc                  |
      | /rooms/99999999999999999999 |

  Scenario Outline: A message cannot be posted to a room that the person is not in
    Given a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And a closed room "Secret" with the members "bea@example.com"
    And a direct room with the members "bea@example.com, cy@example.com"
    When I post to "<path>" the form:
      | body | hello |
    Then the status is 404
    And the body is "Not Found"
    And the query "select count(*) from messages" gives 0

    Examples:
      | path                 |
      | /rooms/2/messages    |
      | /rooms/3/messages    |
      | /rooms/99/messages   |
      | /rooms/abc/messages  |

  Scenario Outline: A visitor with no session is sent to sign in, and nothing is made
    Given the browser has no cookies
    When I get "<path>"
    Then the status is 302
    And the header "location" is "/session/new"

    Examples:
      | path       |
      | /rooms/new |
      | /rooms/1   |

  Scenario Outline: A form from a visitor with no session changes nothing
    Given the browser has no cookies
    When I post to "<path>" the form:
      | name | Lunch |
      | body | hello |
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from rooms" gives 1
    And the query "select count(*) from messages" gives 0

    Examples:
      | path              |
      | /rooms            |
      | /rooms/1/messages |

  Scenario: A page of another site cannot make a room
    Given the request header "sec-fetch-site" is "cross-site"
    When I post to "/rooms" the form:
      | name | Lunch |
    Then the status is 403
    And the query "select count(*) from rooms" gives 1

Feature: Closing a direct message
  A person can close a direct message with the x beside it in the sidebar. It leaves their sidebar and nobody else's
  (their membership is `invisible`), and its page is still there for whoever has the address. A new message brings it
  back for every member who closed it, with the unread mark; so does starting a direct message with the same person
  again, for the person who starts it. This is not what Rails does, on purpose: there a direct message cannot be hidden.
  A shared room has the sidebar setting that it always had. The first admin is Ana, user 1, and "All Talk" is room 1;
  Bea is user 2 and Cy is user 3, so the first room that a scenario makes is room 2.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And a direct room with the members "ana@example.com, bea@example.com"

  Scenario: Closing hides the conversation from the person who closed it only, and the page stays reachable
    When I get "/users/me/sidebar"
    Then the body contains "<form class=\"close\" method=\"post\" action=\"/rooms/2/close\">"
    And the body contains "aria-label=\"Close the conversation with Bea\""
    And the body does not contain "action=\"/rooms/1/close\""
    When I post nothing to "/rooms/2/close"
    Then the status is 302
    And the header "location" is "/"
    And the query "select count(*) from memberships where room_id = 2 and user_id = 1 and involvement = 'invisible'" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id = 2 and involvement = 'invisible'" gives 0
    When I get "/users/me/sidebar"
    Then the body does not contain "Bea"
    And the body contains "<a href=\"/rooms/1\">All Talk</a>"
    When I get "/rooms/2"
    Then the status is 200
    When I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    Then the body contains "<a href=\"/rooms/2\">Ana</a>"

  Scenario: Closing the conversation that the cookie names does not open it again from the home page
    When I get "/rooms/2"
    And I post nothing to "/rooms/2/close"
    And I get "/"
    Then the status is 302
    And the header "location" is "/rooms/1"

  Scenario: A new message brings it back for everyone who closed it, unread for the others and not for its author
    When I post nothing to "/rooms/2/close"
    And I sign in as "bea@example.com"
    And I post nothing to "/rooms/2/close"
    And I sign in as "ana@example.com"
    And I post to "/rooms/2/messages" the form:
      | message[body] | Are you there? |
    Then the query "select count(*) from memberships where room_id = 2 and involvement = 'everything'" gives 2
    When I get "/users/me/sidebar"
    Then the body contains "<li id=\"room_2\"><a href=\"/rooms/2\">Bea</a>"
    When I sign in as "bea@example.com"
    And I get "/users/me/sidebar"
    Then the body contains "<li id=\"room_2\" class=\"unread\"><a href=\"/rooms/2\">Ana<span class=\"sr-only\"> (unread)</span></a>"

  Scenario: A message in a conversation that nobody closed changes no membership
    When I sign in as "bea@example.com"
    And I post to "/rooms/2/messages" the form:
      | message[body] | Hello |
    Then the query "select count(*) from memberships where room_id = 2 and involvement = 'mentions'" gives 2

  Scenario: Starting a direct message with the same person brings it back for the person who starts it only
    When I post nothing to "/rooms/2/close"
    And I sign in as "bea@example.com"
    And I post nothing to "/rooms/2/close"
    And I sign in as "ana@example.com"
    And I post to "/direct_rooms" the form:
      | member | 2 |
    Then the status is 302
    And the header "location" is "/rooms/2"
    And the query "select count(*) from rooms where type = 'Rooms::Direct'" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id = 1 and involvement = 'everything'" gives 1
    And the query "select count(*) from memberships where room_id = 2 and user_id = 2 and involvement = 'invisible'" gives 1
    When I get "/users/me/sidebar"
    Then the body contains "<a href=\"/rooms/2\">Bea</a>"

  Scenario: Only a direct message that the person is in can be closed, and a shared room keeps its choices
    Given a direct room with the members "bea@example.com, cy@example.com"
    When I post nothing to "/rooms/1/close"
    Then the status is 404
    When I post nothing to "/rooms/3/close"
    Then the status is 404
    And the body is "Not Found"
    And the query "select count(*) from memberships where involvement = 'invisible'" gives 0
    When I get "/rooms/1/involvement"
    Then the status is 200
    And the body contains "Hidden from the sidebar"
    When I get "/rooms/2/involvement"
    Then the body contains "close it with the x"

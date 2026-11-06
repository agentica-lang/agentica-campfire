Feature: What deactivating and reactivating a person does
  Deactivating follows Rails Campfire's `User#deactivate`, in one transaction: the sessions, reset links, push
  subscriptions and searches of the person are deleted; they leave every open and closed room (the direct messages stay);
  and their address becomes `name-deactivated-UUID@domain`, which frees it. Their messages and the rooms they made stay.
  Rails has no way back; here an administrator reactivates a person on the people page, which gives them their address
  back (unless it is another account's by then) and every open room that exists, as a new person gets them. The closed
  rooms they left are not given back. The first admin is Ana, user 1, "All Talk" is room 1 (open); Bea is user 2 and Cy
  is user 3. Room 2 is the closed room "Secret" of Ana, Bea and Cy, and room 3 is the direct message of Ana and Bea.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And I run the sql "update accounts set join_code = 'aaaa-bbbb-cccc'"
    And a closed room "Secret" with the members "ana@example.com, bea@example.com, cy@example.com"
    And a direct room with the members "ana@example.com, bea@example.com"
    And the room 1 has 2 messages
    And I run the sql "insert into searches (query, user_id, created_at, updated_at) values ('lunch', 2, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000'), ('lunch', 3, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I run the sql "insert into push_subscriptions (endpoint, user_id, created_at, updated_at) values ('https://push.example/a', 2, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000'), ('https://push.example/b', 3, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"

  Scenario: Deactivating deletes what Rails deletes and keeps the rest
    Given I sign in as "bea@example.com"
    And the browser saves a copy of its cookies
    And I sign in as "ana@example.com"
    When I post to "/users/2/deactivate" the form:
      | x | y |
    Then the status is 302
    And the query "select count(*) from users where id = 2 and status = 1" gives 1
    When the browser restores its saved cookies
    And I get "/rooms/1"
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from sessions where user_id = 2" gives 0
    And the query "select count(*) from searches where user_id = 2" gives 0
    And the query "select count(*) from push_subscriptions where user_id = 2" gives 0
    And the query "select count(*) from memberships where user_id = 2 and room_id in (1, 2)" gives 0
    And the query "select count(*) from memberships where user_id = 2 and room_id = 3" gives 1
    And the query "select count(*) from messages where room_id = 1" gives 2
    And the query "select count(*) from rooms" gives 3
    And the query "select count(*) from searches where user_id = 3" gives 1
    And the query "select count(*) from push_subscriptions where user_id = 3" gives 1
    And the query "select count(*) from memberships where user_id = 3" gives 2

  Scenario: The address is renamed as Rails renames it, and the person cannot sign in with either
    When I post to "/users/2/deactivate" the form:
      | x | y |
    Then the query "select count(*) from users where id = 2 and email_address like 'bea-deactivated-%@example.com' and length(email_address) = 64" gives 1
    And the query "select count(*) from users where id = 2 and email_address glob 'bea-deactivated-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-[0-9a-f]*@example.com'" gives 1
    When I post to "/session" the form:
      | email_address | bea@example.com       |
      | password      | another long password |
    Then the status is 422

  Scenario: The freed address can join as a new person, and then the old person cannot be brought back
    When I post to "/users/2/deactivate" the form:
      | x | y |
    And the browser has no cookies
    And I post to "/join/aaaa-bbbb-cccc" the form:
      | name     | Bea Again             |
      | email    | bea@example.com       |
      | password | another long password |
    Then the status is 302
    And the query "select count(*) from users where email_address = 'bea@example.com' and id = 4" gives 1
    When I sign in as "ana@example.com"
    And I post to "/users/2/reactivate" the form:
      | x | y |
    Then the status is 409
    And the query "select count(*) from users where id = 2 and status = 1 and email_address like 'bea-deactivated-%'" gives 1
    And the query "select count(*) from memberships where user_id = 2" gives 1

  Scenario: Reactivating gives the address and the open rooms back, not the closed room, and keeps the direct message
    When I post to "/users/2/deactivate" the form:
      | x | y |
    And I post to "/rooms" the form:
      | name | Made while away |
    And I post to "/users/2/reactivate" the form:
      | x | y |
    Then the status is 302
    And the query "select count(*) from users where id = 2 and status = 0 and email_address = 'bea@example.com'" gives 1
    And the query "select count(*) from memberships where user_id = 2 and room_id in (1, 4)" gives 2
    And the query "select count(*) from memberships where user_id = 2 and room_id = 2" gives 0
    And the query "select count(*) from memberships where user_id = 2 and room_id = 3" gives 1
    When I sign in as "bea@example.com"
    And I get "/rooms/1"
    Then the status is 200
    When I get "/rooms/2"
    Then the status is 404

  Scenario Outline: A person deactivated by Rails gets the address before the marker, and one deactivated before keeps theirs
    Given a user "Di" with the email "<stored>", the role "member" and the status "deactivated" exists
    When I post to "/users/4/reactivate" the form:
      | x | y |
    Then the status is 302
    And the query "select count(*) from users where id = 4 and status = 0 and email_address = '<after>'" gives 1

    Examples:
      | stored                                                          | after                                                           |
      | di-deactivated-00000000-0000-4000-8000-000000000000@example.com | di@example.com                                                  |
      | di@example.com                                                  | di@example.com                                                  |
      | di-deactivated-x@example.com                                    | di-deactivated-x@example.com                                    |
      | a@x-deactivated-y.com                                           | a@x-deactivated-y.com                                           |
      | di-deactivated-00000000-0000-4000-8000-00000000000g@example.com | di-deactivated-00000000-0000-4000-8000-00000000000g@example.com |
      | di-deactivated-00000000-0000-4000-8000-000000000000@a@b.com     | di-deactivated-00000000-0000-4000-8000-000000000000@a@b.com     |

  Scenario: An address that has the marker by its owner's choice comes back as it was typed
    Given a member "Xe" with the email "x-deactivated-1@example.com" exists
    When I post to "/users/4/deactivate" the form:
      | x | y |
    Then the query "select count(*) from users where id = 4 and email_address glob 'x-deactivated-1-deactivated-*@example.com' and length(email_address) = 76" gives 1
    When I post to "/users/4/reactivate" the form:
      | x | y |
    Then the status is 302
    And the query "select count(*) from users where id = 4 and status = 0 and email_address = 'x-deactivated-1@example.com'" gives 1

  Scenario: Deactivating twice and reactivating twice change nothing the second time
    When I post to "/users/2/deactivate" the form:
      | x | y |
    And I post to "/users/2/deactivate" the form:
      | x | y |
    Then the status is 302
    And the query "select count(*) from users where id = 2 and email_address like 'bea-deactivated-%-deactivated-%'" gives 0
    When I post to "/users/2/reactivate" the form:
      | x | y |
    And I post to "/users/2/reactivate" the form:
      | x | y |
    Then the status is 302
    And the query "select count(*) from users where id = 2 and email_address = 'bea@example.com'" gives 1

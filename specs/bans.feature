Feature: Bans
  An administrator bans a person from the person's page (`Users::BansController`, `User::Bannable`): the person's
  sessions end, one ban holds each public address their sessions came from, their sockets close and their messages
  go; a request that changes something from a banned address gets 429, and a request that reads is served. Lifting
  the ban makes the person active again. An administrator cannot ban themselves. The first admin is Ana, user 1; Bea
  is user 2 and Cy is user 3; Di (user 4) is deactivated and the bot Robo is user 5. Room 1, "All Talk", has the
  messages of Bea and of Cy.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And a user "Di" with the email "di@example.com", the role "member" and the status "deactivated" exists
    And a bot "Robo" with the token "robo-token" exists
    And I run the sql "insert into sessions (user_id, token, ip_address, user_agent, last_active_at, created_at, updated_at) values (2, 't1', '8.8.8.8', 'a', strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now')), (2, 't2', '8.8.8.8', 'a', strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now')), (2, 't3', '1.1.1.1', 'a', strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now')), (2, 't4', '10.0.0.5', 'a', strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now')), (2, 't5', '', 'a', strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now')), (3, 't6', '9.9.9.9', 'a', strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'))"
    And I run the sql "insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) values (1, 2, 'm1', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000'), (1, 2, 'm2', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000'), (1, 3, 'm3', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I sign in as "bea@example.com"
    And I sign in as "ana@example.com"

  Scenario: The user page of a person has the ban button for an administrator only, and the one of a banned person lifts it
    When I get "/users/2"
    Then the status is 200
    And the body contains "<form method=\"post\" action=\"/users/2/ban\""
    And the body contains "Ban Bea"
    And the body does not contain "Remove ban"
    When I get "/users/1"
    Then the body does not contain "/users/1/ban"
    When I get "/users/4"
    Then the body does not contain "/ban"
    When I get "/users/5"
    Then the body does not contain "/ban"
    When I sign in as "cy@example.com"
    And I get "/users/2"
    Then the body does not contain "/ban"

  Scenario: A ban ends the sessions, holds each public address once, removes the messages and lists the person as banned
    When I post to "/users/2/ban" the form:
      | x | y |
    Then the status is 302
    And the header "location" is "/users/2"
    And the query "select count(*) from users where id = 2 and status = 2" gives 1
    And the query "select count(*) from sessions where user_id = 2" gives 0
    And the query "select count(*) from sessions where user_id = 3" gives 1
    And the query "select count(*) from bans where user_id = 2" gives 2
    And the query "select count(*) from bans where user_id = 2 and ip_address in ('8.8.8.8', '1.1.1.1')" gives 2
    And the query "select count(*) from messages where creator_id = 2" gives 0 within 5000 milliseconds
    And the query "select count(*) from messages where creator_id = 3" gives 1
    And the query "select count(*) from users where id = 2" gives 1
    When I get "/users/2"
    Then the body contains "Banned"
    And the body contains "Remove ban"
    And the body does not contain "Ban Bea"
    When I get "/users"
    Then the body contains "<span class=\"badge\">banned</span>"
    And the body does not contain "action=\"/users/2/deactivate\""
    And the body does not contain "action=\"/users/2/reactivate\""
    When I sign in as "cy@example.com"
    And I get "/users"
    Then the body does not contain "Bea"

  Scenario: A banned person cannot sign in and cannot be written to
    When I post to "/users/2/ban" the form:
      | x | y |
    And the browser has no cookies
    And I post to "/session" the form:
      | email_address | bea@example.com       |
      | password      | another long password |
    Then the status is 422
    When I sign in as "ana@example.com"
    And I get "/users/2"
    Then the body does not contain "Write to"

  Scenario: Lifting the ban makes the person active again, with the same address free
    When I post to "/users/2/ban" the form:
      | x | y |
    And I post to "/users/2/ban" the form:
      | _method | delete |
    Then the status is 302
    And the header "location" is "/users/2"
    And the query "select count(*) from users where id = 2 and status = 0" gives 1
    And the query "select count(*) from bans where user_id = 2" gives 0
    When the browser has no cookies
    And I post to "/session" the form:
      | email_address | bea@example.com       |
      | password      | another long password |
    Then the status is 302
    And the header "location" is "/"

  Scenario: A real DELETE lifts the ban too, and a repeat of either is no failure
    When I post to "/users/2/ban" the form:
      | x | y |
    And I post to "/users/2/ban" the form:
      | x | y |
    Then the status is 302
    And the query "select count(*) from bans where user_id = 2" gives 2
    When I send a DELETE to "/users/2/ban"
    Then the status is 302
    When I send a DELETE to "/users/2/ban"
    Then the status is 302
    And the query "select count(*) from users where id = 2 and status = 0" gives 1

  Scenario Outline: Only an address of the open internet is held by a ban, not a local, shared, documentation or reserved one
    Given I run the sql "delete from sessions where user_id = 3"
    And I run the sql "insert into sessions (user_id, token, ip_address, user_agent, last_active_at, created_at, updated_at) values (3, 'x', '<address>', 'a', strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'))"
    When I post to "/users/3/ban" the form:
      | x | y |
    Then the status is 302
    And the query "select count(*) from bans where user_id = 3" gives <bans>

    Examples:
      | address              | bans |
      | 8.8.8.8              | 1    |
      | 2606:4700::1111      | 1    |
      | ::ffff:8.8.8.8       | 1    |
      | ::ffff:808:808       | 1    |
      | 100.128.0.1          | 1    |
      | 172.32.0.1           | 1    |
      | 198.20.0.1           | 1    |
      | 127.0.0.1            | 0    |
      | 10.1.2.3             | 0    |
      | 172.16.0.1           | 0    |
      | 192.168.1.1          | 0    |
      | 169.254.1.1          | 0    |
      | 100.64.0.1           | 0    |
      | 100.127.255.254      | 0    |
      | 0.0.0.0              | 0    |
      | 192.0.0.8            | 0    |
      | 192.0.2.1            | 0    |
      | 198.18.0.1           | 0    |
      | 198.19.255.1         | 0    |
      | 198.51.100.7         | 0    |
      | 203.0.113.9          | 0    |
      | 224.0.0.1            | 0    |
      | 240.0.0.1            | 0    |
      | 255.255.255.255      | 0    |
      | ::1                  | 0    |
      | ::                   | 0    |
      | fe80::1              | 0    |
      | fec0::1              | 0    |
      | fd00::1              | 0    |
      | ff02::1              | 0    |
      | 2001:2::1            | 0    |
      | 2001:2:1::1          | 1    |
      | 3fff::1              | 0    |
      | 3fff:1000::1         | 1    |
      | 3ffe::1              | 1    |
      | 1fff::1              | 0    |
      | 4000::1              | 0    |
      | 2001:db8:0:0:0:0:0:1 | 0    |
      | 2001:0db8::1         | 0    |
      | 2001:4860:4860::8888 | 1    |
      | 2001:db8::1          | 0    |
      | ::ffff:7f00:1        | 0    |
      | ::ffff:a00:1         | 0    |
      | ::ffff:10.0.0.1      | 0    |
      | ::ffff:6440:1        | 0    |
      | not an address       | 0    |
      | 999.1.1.1            | 0    |

  Scenario: A request that changes something from a banned address gets 429 and a read is served
    Given I run the sql "insert into bans (ip_address, user_id, created_at, updated_at) values ('127.0.0.1', 3, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And the app restarts
    When I get "/rooms/1"
    Then the status is 200
    When I post to "/rooms/1/messages" the form:
      | message[body] | hello |
    Then the status is 429
    When I post to "/session" the form:
      | email_address | ana@example.com       |
      | password      | correct horse battery |
    Then the status is 429
    When I send a DELETE to "/users/3/ban"
    Then the status is 429
    And the query "select count(*) from messages where room_id = 1" gives 3
    When I run the sql "delete from bans"
    And the app restarts
    And I post to "/session" the form:
      | email_address | ana@example.com       |
      | password      | correct horse battery |
    Then the status is 302

  Scenario: The removal of the messages stops when the person is not banned any more
    Given I run the sql "update users set status = 0 where id = 2"
    When the messages of the user 2 are taken away as the removal task takes them
    Then the query "select count(*) from messages where creator_id = 2" gives 2
    When I run the sql "update users set status = 2 where id = 2"
    And the messages of the user 2 are taken away as the removal task takes them
    Then the query "select count(*) from messages where creator_id = 2" gives 0
    And the query "select count(*) from messages where creator_id = 3" gives 1

  Scenario: A person who was unbanned can be banned again, and writes after the unban stay until then
    When I post to "/users/2/ban" the form:
      | x | y |
    And I post to "/users/2/ban" the form:
      | _method | delete |
    And I run the sql "insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) values (1, 2, 'm9', '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I run the sql "insert into sessions (user_id, token, ip_address, user_agent, last_active_at, created_at, updated_at) values (2, 'u1', '4.4.4.4', 'a', strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'), strftime('%Y-%m-%d %H:%M:%f000', 'now'))"
    Then the query "select count(*) from messages where creator_id = 2 and client_message_id = 'm9'" gives 1
    When I post to "/users/2/ban" the form:
      | x | y |
    Then the status is 302
    And the query "select count(*) from users where id = 2 and status = 2" gives 1
    And the query "select count(*) from bans where user_id = 2 and ip_address = '4.4.4.4'" gives 1
    And the query "select count(*) from messages where creator_id = 2" gives 0 within 5000 milliseconds

  Scenario: A ban row added by hand is not seen until a restart once a write has found no ban
    When I post to "/rooms/1/messages" the form:
      | message[body] | before |
    Then the status is 302
    When I run the sql "insert into bans (ip_address, user_id, created_at, updated_at) values ('127.0.0.1', 3, '2026-03-01 09:00:00.000000', '2026-03-01 09:00:00.000000')"
    And I post to "/rooms/1/messages" the form:
      | message[body] | still passes |
    Then the status is 302
    When the app restarts
    And I post to "/rooms/1/messages" the form:
      | message[body] | refused |
    Then the status is 429

  Scenario Outline: Only an administrator bans, not oneself, and only an active person
    When I sign in as "<actor>"
    And I post to "<path>" the form:
      | x | y |
    Then the status is <status>
    And the query "select count(*) from users where status = 2" gives 0

    Examples:
      | actor           | path           | status |
      | cy@example.com  | /users/2/ban   | 403    |
      | cy@example.com  | /users/99/ban  | 403    |
      | ana@example.com | /users/1/ban   | 403    |
      | ana@example.com | /users/99/ban  | 404    |
      | ana@example.com | /users/abc/ban | 404    |
      | ana@example.com | /users/4/ban   | 404    |
      | ana@example.com | /users/5/ban   | 404    |

  Scenario: Lifting a ban is refused to a member and to oneself, and a person who was never banned is 404 or no change
    When I sign in as "cy@example.com"
    And I send a DELETE to "/users/2/ban"
    Then the status is 403
    When I sign in as "ana@example.com"
    And I send a DELETE to "/users/1/ban"
    Then the status is 403
    When I send a DELETE to "/users/4/ban"
    Then the status is 404
    When I send a DELETE to "/users/99/ban"
    Then the status is 404
    And the query "select count(*) from users where id = 4 and status = 1" gives 1

  Scenario: A visitor is sent to sign in, a page of another site changes nothing, and other methods are 405
    Given the browser has no cookies
    When I post to "/users/2/ban" the form:
      | x | y |
    Then the status is 302
    And the header "location" is "/session/new"
    Given I sign in as "ana@example.com"
    And the request header "sec-fetch-site" is "cross-site"
    When I post to "/users/2/ban" the form:
      | x | y |
    Then the status is 403
    When I send a DELETE to "/users/2/ban"
    Then the status is 403
    Given the request header "sec-fetch-site" is "same-origin"
    When I post to "/users/2/ban" the form:
      | _method | patch |
    Then the status is 405
    And the header "allow" is "POST, DELETE"
    When I send a PATCH to "/users/2/ban" the form:
      | x | y |
    Then the status is 405
    And the query "select count(*) from users where status = 2" gives 0

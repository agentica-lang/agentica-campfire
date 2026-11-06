Feature: The cache of rendered messages
  The room page and the page of older messages keep the markup of each message in a cache (`CAMPFIRE_CACHE_MB`, 64 by
  default, 0 for none), as Rails Campfire caches its message partial. The key holds what the markup is made of (the
  id, `updated_at`, and a digest of the author, the time and the body), so whatever changes a message, with or without
  a new `updated_at`, shows at once, and the page is the same bytes with the cache on and off. The room is room 1, "All
  Talk", and the person is the first admin, user 1, "Ana".

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: A room page that is served from the cache is the page that the cache off writes
    Given a message "Timed" in the room 1 at "2026-03-01 09:00:00.123456"
    And I run the sql "insert into messages (room_id, creator_id, client_message_id, created_at, updated_at) values (1, 1, 'rails', '2026-03-01 10:00:00.000000', '2026-03-01 10:00:00.000000')"
    And I run the sql "insert into action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at) values ('Message', 2, 'body', '<div>Seen <img src=x onerror=alert(1)><strong>bold</strong> <a href=\"https://example.com/?a=1&b=2\">link</a></div>', '2026-03-01 10:00:00.000000', '2026-03-01 10:00:00.000000')"
    When I post to "/rooms/1/messages" the form:
      | message[body] | <b>plain</b> & text |
    And I get "/rooms/1"
    Then the status is 200
    When I remember the messages of the page
    And I get "/rooms/1"
    Then the messages of the page are the ones that I remembered
    When the app restarts with the message cache off
    And I get "/rooms/1"
    Then the status is 200
    And the messages of the page are the ones that I remembered
    And the body does not contain "onerror"

  Scenario: The page of older messages is the same from the cache and without it
    Given the room 1 has 45 messages
    When I get "/rooms/1/messages?before=45"
    Then the status is 200
    When I remember the answer
    And I get "/rooms/1/messages?before=45"
    Then the answer is the one that I remembered
    When the app restarts with the message cache off
    And I get "/rooms/1/messages?before=45"
    Then the answer is the one that I remembered

  Scenario: A rename of the author and an edit of the body show at once, though updated_at does not change
    Given a message "First words" in the room 1 at "2026-03-01 09:00:00.000000"
    When I get "/rooms/1"
    Then the body contains "First words"
    And the body contains "Ana"
    When I run the sql "update users set name = 'Anna' where id = 1"
    And I get "/rooms/1"
    Then the body contains "<strong>Anna</strong>"
    And the body does not contain "<strong>Ana</strong>"
    When I run the sql "update action_text_rich_texts set body = '<p>Second words</p>' where record_id = 1"
    And I get "/rooms/1"
    Then the body contains "<p>Second words</p>"
    And the body does not contain "First words"

  Scenario: A change of the time of a message alone shows at once
    Given a message "Timed" in the room 1 at "2026-03-01 09:00:00.123456"
    When I get "/rooms/1"
    Then the body contains "<time datetime=\"2026-03-01T09:00:00.123Z\" title=\"2026-03-01T09:00:00.123Z\">"
    When I run the sql "update messages set created_at = '2026-04-05 06:07:08.000000' where id = 1"
    And I get "/rooms/1"
    Then the body contains "<time datetime=\"2026-04-05T06:07:08.000Z\" title=\"2026-04-05T06:07:08.000Z\">"
    And the body does not contain "2026-03-01T09:00:00.123Z"

  Scenario: An edit that moves updated_at and a delete show at once
    Given a message "Keep" in the room 1 at "2026-03-01 09:00:00.000000"
    And a message "Drop" in the room 1 at "2026-03-01 09:01:00.000000"
    When I get "/rooms/1"
    Then the body contains "Keep"
    And the body contains "Drop"
    When I run the sql "update messages set updated_at = '2026-03-02 09:00:00.000000' where id = 1"
    And I run the sql "update action_text_rich_texts set body = 'Kept new' where record_id = 1"
    And I run the sql "delete from messages where id = 2"
    And I get "/rooms/1"
    Then the body contains "Kept new"
    And the body does not contain "Drop"

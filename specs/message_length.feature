Feature: The longest message
  `CAMPFIRE_MAX_MESSAGE_LENGTH` (10000 by default) is the most characters that a body may have, for a new message and
  for an edit. It is checked on what is sent, before the sanitizer reads it, so a long text never costs the work of
  cleaning it. The cap here is 20 characters. The first admin is Ana, user 1, and "All Talk" is room 1.

  Background:
    Given a fresh database
    And the app starts with messages of at most 20 characters
    And the first admin exists

  Scenario: A message over the cap is refused and nothing is written
    When I post to "/rooms/1/messages" a message of 20 characters
    Then the status is 302
    When I post to "/rooms/1/messages" a message of 21 characters
    Then the status is 422
    And the body contains "A message is at most 20 characters"
    And the query "select count(*) from messages" gives 1
    And the query "select count(*) from action_text_rich_texts" gives 1
    And the query "select count(*) from message_search_index" gives 1

  Scenario: An edit over the cap is refused and the message stays
    When I post to "/rooms/1/messages" a message of 20 characters
    And I send a PATCH to "/rooms/1/messages/1" a message of 21 characters
    Then the status is 422
    And the body contains "A message is at most 20 characters"
    When I send a PATCH to "/rooms/1/messages/1" a message of 20 characters
    Then the status is 302

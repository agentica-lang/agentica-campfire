Feature: The webhooks of the chat bots
  As Rails Campfire (`Webhook`, `Bot::WebhookJob`, `MessagesController#deliver_webhooks_to_bots`), a bot with a webhook
  URL gets the messages of people meant for it as a JSON post: every message of a direct room it is in, and in another
  room the messages that mention it (until mentions exist, the text `@NAME`). A message that a bot posts through the API
  goes to no webhook, so two bots cannot answer each other forever. An answer
  `200` of `text/html` or `text/plain` is posted back to the room as a message of the bot, and an answer that takes too
  long is answered "Failed to respond within N seconds". A webhook reaches only addresses of the open internet unless
  `CAMPFIRE_WEBHOOK_PRIVATE_ADDRESSES` is true. The webhook here is a Python server on 127.0.0.1. The first admin is
  Ana, user 1, "All Talk" is room 1 (open); the bot Robo is user 2 (token `aaaaBBBB1111`), made on the bots page so
  that it joins the open rooms.

  Scenario: An administrator sets the webhook URL of a bot, sees it on the edit page and takes it away
    Given a fresh database
    And the app starts
    And the first admin exists
    When I get "/account/bots/new"
    Then the body contains "name=\"user[webhook_url]\" type=\"url\""
    When I post to "/account/bots" the form:
      | user[name]        | Robo                     |
      | user[webhook_url] | https://bots.example/robo |
    Then the status is 302
    And the query "select count(*) from webhooks where user_id = 2 and url = 'https://bots.example/robo'" gives 1
    When I get "/account/bots/2/edit"
    Then the body contains "value=\"https://bots.example/robo\""
    When I post to "/account/bots/2" the form:
      | _method           | patch                   |
      | user[name]        | Robo                    |
      | user[webhook_url] | ftp://bots.example/robo |
    Then the status is 422
    And the query "select count(*) from webhooks where user_id = 2 and url = 'https://bots.example/robo'" gives 1
    When I post to "/account/bots/2" the form:
      | _method           | patch |
      | user[name]        | Robo  |
      | user[webhook_url] |       |
    Then the status is 302
    And the query "select count(*) from webhooks" gives 0

  Scenario: A mention of a bot posts the payload of Rails, and the text of the answer becomes a message of the bot
    Given a fresh database
    And the webhook answers "Hi <b>Ana</b>" as "text/html; charset=utf-8"
    And the webhook is listening
    And the app starts with webhooks to private addresses that wait 7 seconds
    And the first admin exists
    And I post to "/account/bots" the form:
      | user[name] | Robo |
    And I run the sql "update users set bot_token = 'aaaaBBBB1111' where id = 2"
    And the bot 2 has the webhook at "/robo"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Hello @Robo, how is the deploy? |
    Then the status is 302
    When the webhook receives a post
    Then the post contains "\"path\": \"/robo\""
    And the post contains "\"content_type\": \"application/json\""
    And the post contains "\"user\": {\"id\": 1, \"name\": \"Ana\"}"
    And the post contains "\"room\": {\"id\": 1, \"name\": \"All Talk\", \"path\": \"/rooms/1/2-aaaaBBBB1111/messages\"}"
    And the post contains "\"plain\": \"Hello , how is the deploy?\""
    And the post contains "\"path\": \"/rooms/1/@1\""
    And the query "select count(*) from messages where creator_id = 2" gives 1 within 5000 milliseconds
    And the query "select count(*) from messages join action_text_rich_texts on record_id = messages.id where creator_id = 2 and body = 'Hi <b>Ana</b>'" gives 1
    And the webhook receives nothing within 1000 milliseconds

  Scenario: A webhook that answers too late gets the message of Rails in its name
    Given a fresh database
    And the webhook answers after 3000 milliseconds
    And the webhook is listening
    And the app starts with webhooks to private addresses that wait 1 seconds
    And the first admin exists
    And I post to "/account/bots" the form:
      | user[name] | Robo |
    And the bot 2 has the webhook at "/robo"
    When I post to "/rooms/1/messages" the form:
      | message[body] | @Robo ping |
    Then the webhook receives a post
    And the query "select count(*) from messages join action_text_rich_texts on record_id = messages.id where creator_id = 2 and body = 'Failed to respond within 1 second'" gives 1 within 5000 milliseconds

  Scenario: A direct room delivers every message without a mention, and another room only the mentions
    Given a fresh database
    And the webhook is listening
    And the app starts with webhooks to private addresses that wait 7 seconds
    And the first admin exists
    And I post to "/account/bots" the form:
      | user[name] | Robo |
    And the bot 2 has the webhook at "/robo"
    And a direct room with the members "ana@example.com"
    And I run the sql "insert into memberships (room_id, user_id, involvement, created_at, updated_at) values (2, 2, 'everything', '2026-01-01 00:00:00', '2026-01-01 00:00:00')"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Robocop is not @Robot |
    And I post to "/rooms/2/messages" the form:
      | message[body] | Just us |
    Then the webhook receives a post
    And the post contains "\"room\": {\"id\": 2, \"name\": null"
    And the post contains "\"plain\": \"Just us\""

  Scenario: A post of the bots API goes to no webhook, even one that mentions another bot
    Given a fresh database
    And the webhook is listening
    And the app starts with webhooks to private addresses that wait 7 seconds
    And the first admin exists
    And I post to "/account/bots" the form:
      | user[name] | Robo |
    And I post to "/account/bots" the form:
      | user[name] | Echo |
    And I run the sql "update users set bot_token = 'aaaaBBBB1111' where id = 2"
    And the bot 2 has the webhook at "/robo"
    And the bot 3 has the webhook at "/echo"
    When I send "POST" to "/rooms/1/2-aaaaBBBB1111/messages" the text "@Robo and @Echo, hello"
    Then the status is 201
    And the webhook receives nothing within 1500 milliseconds

  Scenario: A slow webhook does not hold up the webhook of another bot
    Given a fresh database
    And the webhook answers "Here" as "text/plain"
    And the webhook answers after 5000 milliseconds only on "/slow"
    And the webhook is listening
    And the app starts with webhooks to private addresses that wait 7 seconds
    And the first admin exists
    And I post to "/account/bots" the form:
      | user[name] | Slow |
    And I post to "/account/bots" the form:
      | user[name] | Fast |
    And the bot 2 has the webhook at "/slow"
    And the bot 3 has the webhook at "/fast"
    When I post to "/rooms/1/messages" the form:
      | message[body] | @Slow and @Fast, who is there? |
    Then the query "select count(*) from messages where creator_id = 3" gives 1 within 2500 milliseconds
    And the query "select count(*) from messages where creator_id = 2" gives 0
    And the query "select count(*) from messages where creator_id = 2" gives 1 within 6000 milliseconds

  Scenario: Without the setting, a webhook on a loopback address gets nothing
    Given a fresh database
    And the webhook is listening
    And the app starts
    And the first admin exists
    And I post to "/account/bots" the form:
      | user[name] | Robo |
    And the bot 2 has the webhook at "/robo"
    When I post to "/rooms/1/messages" the form:
      | message[body] | @Robo hello |
    Then the status is 302
    And the webhook receives nothing within 2000 milliseconds
    And the query "select count(*) from messages where creator_id = 2" gives 0

  Scenario: One bot has at most 4 posts under way, and the next waits for one of them
    Given a fresh database
    And the webhook answers after 3000 milliseconds
    And the webhook is listening
    And the app starts with webhooks to private addresses that wait 7 seconds
    And the first admin exists
    And I post to "/account/bots" the form:
      | user[name] | Slow |
    And the bot 2 has the webhook at "/slow"
    When I post to "/rooms/1/messages" the form:
      | message[body] | @Slow one |
    And I post to "/rooms/1/messages" the form:
      | message[body] | @Slow two |
    And I post to "/rooms/1/messages" the form:
      | message[body] | @Slow three |
    And I post to "/rooms/1/messages" the form:
      | message[body] | @Slow four |
    And I post to "/rooms/1/messages" the form:
      | message[body] | @Slow five |
    Then the webhook receives a post
    And the webhook receives a post
    And the webhook receives a post
    And the webhook receives a post
    And the webhook receives nothing within 1500 milliseconds

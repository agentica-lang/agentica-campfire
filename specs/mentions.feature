Feature: Mentions and the people that a mention may name
  As in Rails Campfire (`User::Mentionable`, `Message::Mentionee`, `Autocompletable::UsersController`), a message can
  mention people. A mention is stored as an Action Text attachment of the type `application/vnd.campfire.mention` with
  the GlobalID of the user and the text `@NAME`. A typed `@NAME` of an active person of the room becomes one (the longest
  name wins, and an `@` after a letter, as in an email address, is no mention); a mention in an HTML body stays only for
  an active person of the room, with their name, and any other is left as its text. `/autocompletable/users` lists the
  active people, of a room the person is in, whose name holds `filter` or `query`, 20 a page. The first admin is Ana,
  user 1, "All Talk" is room 1 (open), Bea is user 2, Bea Lopez user 3 and Cy (user 4) is not active.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Bea Lopez" with the email "lopez@example.com" exists
    And a user "Cy" with the email "cy@example.com", the role "member" and the status "deactivated" exists
    And I run the sql "insert into memberships (room_id, user_id, involvement, created_at, updated_at) values (1, 4, 'mentions', '2026-01-01 00:00:00', '2026-01-01 00:00:00')"
    And a closed room "Quiet" with the members "ana@example.com"

  Scenario: A typed @name of a person of the room is stored and shown as a mention, and an edit makes them again
    Given I sign in as "ana@example.com"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Hi @Bea Lopez, @Bea and @Nobody; @Cy, write to ana@Bea.com or @Beatrix |
    Then the status is 302
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = 'Hi <action-text-attachment content-type=\"application/vnd.campfire.mention\" gid=\"gid://campfire/User/3\">@Bea Lopez</action-text-attachment>, <action-text-attachment content-type=\"application/vnd.campfire.mention\" gid=\"gid://campfire/User/2\">@Bea</action-text-attachment> and @Nobody; @Cy, write to ana@Bea.com or @Beatrix'" gives 1
    And the query "select count(*) from message_search_index where rowid = 1 and body = 'Hi @Bea Lopez, @Bea and @Nobody; @Cy, write to ana@Bea.com or @Beatrix'" gives 1
    When I get "/rooms/1"
    Then the body contains "<div id=\"presentation_message_1\">Hi <action-text-attachment content-type=\"application/vnd.campfire.mention\" gid=\"gid://campfire/User/3\">@Bea Lopez</action-text-attachment>, <action-text-attachment content-type=\"application/vnd.campfire.mention\" gid=\"gid://campfire/User/2\">@Bea</action-text-attachment> and @Nobody;"
    When I get "/rooms/1/messages/1/edit"
    Then the body contains ">Hi @Bea Lopez, @Bea and @Nobody; @Cy, write to ana@Bea.com or @Beatrix</textarea>"
    When I post to "/rooms/1/messages/1" the form:
      | _method       | patch         |
      | message[body] | Only @Bea now |
    Then the status is 302
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = 'Only <action-text-attachment content-type=\"application/vnd.campfire.mention\" gid=\"gid://campfire/User/2\">@Bea</action-text-attachment> now'" gives 1

  Scenario: A mention reaches only an active person of the room, and its markup is cleaned
    Given I sign in as "ana@example.com"
    When I post to "/rooms/2/messages" the form:
      | message[body] | @Bea look |
    Then the query "select count(*) from action_text_rich_texts where record_id = 1 and body = '@Bea look'" gives 1
    When I post to "/rooms/2/messages" the form:
      | message[format] | html                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
      | message[body]   | <action-text-attachment content-type="application/vnd.campfire.mention" gid="gid://campfire/User/2" onclick="x()">@Bea<script>alert(1)</script></action-text-attachment> <action-text-attachment content-type="application/vnd.campfire.mention" gid="gid://campfire/User/1"><b>@Boss</b></action-text-attachment> <action-text-attachment sgid="abc" content-type="application/vnd.campfire.mention">@Old</action-text-attachment> <action-text-attachment content-type="text/html" gid="gid://campfire/User/1">x</action-text-attachment> |
    Then the status is 302
    And the query "select count(*) from action_text_rich_texts where record_id = 2 and body = '@Bea <action-text-attachment content-type=\"application/vnd.campfire.mention\" gid=\"gid://campfire/User/1\">@Ana</action-text-attachment> @Old x'" gives 1

  Scenario: The people of a room are listed by name, as prompt items and as JSON, and only for a person of the room
    Given I sign in as "bea@example.com"
    When I get "/autocompletable/users?room_id=1&filter=bea"
    Then the status is 200
    And the header "cache-control" is "no-store"
    And the body contains "<lexxy-prompt-item search=\"Bea\" gid=\"gid://campfire/User/2\">"
    And the body contains "<template type=\"editor\"><action-text-attachment content-type=\"application/vnd.campfire.mention\" gid=\"gid://campfire/User/2\">@Bea</action-text-attachment></template>"
    And the body shows "search=\"Bea\"" before "search=\"Bea Lopez\""
    And the body does not contain "search=\"Ana\""
    When I get "/autocompletable/users.json?room_id=1&query=LOP"
    Then the body starts with "[{\"avatar_url\":\"/users/"
    And the body ends with "\"gid\":\"gid://campfire/User/3\",\"name\":\"Bea Lopez\",\"value\":3}]"
    When I get "/autocompletable/users?query=cy"
    Then the status is 200
    And the body does not contain "Cy"
    When I get "/autocompletable/users?room_id=2"
    Then the status is 404
    When I get "/autocompletable/users.json?room_id=x"
    Then the status is 404
    When the browser has no cookies
    And I get "/autocompletable/users"
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: The people come 20 a page
    Given I run the sql "insert into users (name, role, status, created_at, updated_at) with recursive n(i) as (select 1 union all select i + 1 from n where i < 20) select 'Zed ' || printf('%02d', i), 0, 0, '2026-01-01 00:00:00', '2026-01-01 00:00:00' from n"
    And I sign in as "bea@example.com"
    When I get "/autocompletable/users"
    Then the body contains "<lexxy-prompt-item " 20 times
    And the body contains "search=\"Ana\""
    And the body contains "search=\"Zed 17\""
    And the body does not contain "Zed 18"
    When I get "/autocompletable/users?page=2"
    Then the body contains "<lexxy-prompt-item " 3 times
    And the body contains "search=\"Zed 18\""
    And the body contains "search=\"Zed 20\""

Feature: Replies quote a message
  As in Rails Campfire (`reply_controller.js`), Reply on a message puts a quote of it into the composer, with a mention
  of its author after it. The composer is a text box, so the script writes the quote as lines that start with `> `
  (the markdown of Rails' editor), and each run of them is stored as a `blockquote`. Its text is escaped and makes no
  mention, as Rails' reply drops the mentions of the message it quotes; the line after it is typed text, where the
  author is a mention only when they are an active person of the room. The edit form gives the quote back as it was
  typed. The first admin is Ana, user 1, "All Talk" is room 1 (open), Bea is user 2 and Cy (user 3) is not in "Quiet".

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And a member "Cy" with the email "cy@example.com" exists
    And a closed room "Quiet" with the members "ana@example.com,bea@example.com"

  Scenario: A quote is stored as a blockquote, and the author after it is a mention
    Given I sign in as "ana@example.com"
    When I post to "/rooms/1/messages" the message:
      """
      > Hi @Cy, <b>look</b>
      > here
      @Bea agreed
      """
    Then the status is 302
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = '<blockquote>Hi @Cy, &lt;b&gt;look&lt;/b&gt;<br>here</blockquote><action-text-attachment content-type=\"application/vnd.campfire.mention\" gid=\"gid://campfire/User/2\">@Bea</action-text-attachment> agreed'" gives 1
    And the query "select count(*) from message_search_index where rowid = 1 and body = 'Hi @Cy, <b>look</b>' || char(10) || 'here' || char(10) || '@Bea agreed'" gives 1
    When I get "/rooms/1"
    Then the body contains "<div id=\"presentation_message_1\"><blockquote>Hi @Cy, &lt;b&gt;look&lt;/b&gt;<br>here</blockquote><action-text-attachment"
    When I get "/rooms/1/messages/1/edit"
    Then the body contains ">&gt; Hi @Cy, &lt;b&gt;look&lt;/b&gt;"
    And the body shows "&gt; here" before "@Bea agreed</textarea>"

  Scenario: The author of the quote is a mention only for a person of the room
    Given I sign in as "ana@example.com"
    When I post to "/rooms/2/messages" the message:
      """
      > see you
      @Cy ok
      """
    Then the status is 302
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = '<blockquote>see you</blockquote>@Cy ok'" gives 1

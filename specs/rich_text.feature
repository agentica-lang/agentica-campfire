Feature: The rich text of a message
  The editor of Rails Campfire (Lexxy) sends the body of a message as HTML. Here the form says so with
  `message[format]=html`: the body is then cleaned by the sanitizer instead of being escaped as text, so the tags that
  the editor writes (bold, strikethrough, underline, highlight, headings, lists, quotes, tables, code blocks) stay
  and `script` goes. Without the field the textarea of the page sends plain text, which stays text. The body of a bot
  is always HTML. A message is stored as it was sent and cleaned, never with links: the links of the text of a
  message (URLs, `www.` and email addresses) are made when it is shown, as `auto_link_text` of Rails does, and the
  JSON of the bots API shows the stored HTML. A code block keeps its language as `data-language`. The first admin is
  Ana, user 1, "All Talk" is room 1 (open) and Bea is user 2. The bot Robo is user 3 (token `aaaaBBBB1111`).

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And I post to "/account/bots" the form:
      | user[name] | Robo |
    And I run the sql "update users set bot_token = 'aaaaBBBB1111' where id = 3"

  Scenario: A form body that is HTML is stored cleaned, with the tags of the editor kept and the script gone
    Given I sign in as "ana@example.com"
    When I post to "/rooms/1/messages" the form:
      | message[format] | html                                                                                                                  |
      | message[body]   | <h2>Plan</h2><p>Hi <strong>all</strong> <s>old</s> <u>new</u> <mark>hot</mark></p><script>alert(1)</script><img src=x onerror=alert(2)> |
    Then the status is 302
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = '<h2>Plan</h2><p>Hi <strong>all</strong> <s>old</s> <u>new</u> <mark>hot</mark></p>'" gives 1
    And the query "select count(*) from message_search_index where rowid = 1 and body like 'Plan%Hi all old new hot'" gives 1
    When I get "/rooms/1"
    Then the body contains "<div id=\"presentation_message_1\"><h2>Plan</h2><p>Hi <strong>all</strong> <s>old</s> <u>new</u> <mark>hot</mark></p></div>"
    And the body does not contain "alert(1)"

  Scenario: A form body without the mark is text, whatever it looks like
    Given I sign in as "ana@example.com"
    When I post to "/rooms/1/messages" the form:
      | message[body] | <strong>not bold</strong> |
    Then the query "select count(*) from action_text_rich_texts where record_id = 1 and body = '&lt;strong&gt;not bold&lt;/strong&gt;'" gives 1
    When I post to "/rooms/1/messages" the form:
      | message[format] | plain               |
      | message[body]   | <strong>nor</strong> |
    Then the query "select count(*) from action_text_rich_texts where record_id = 2 and body = '&lt;strong&gt;nor&lt;/strong&gt;'" gives 1

  Scenario: The URLs and the email addresses of a message are links on the page, and the stored body has none
    Given I sign in as "ana@example.com"
    When I post to "/rooms/1/messages" the form:
      | message[body] | Docs at https://example.com/a?b=1&c=2. Write to ana@example.com or see www.example.org (soon) |
    Then the query "select count(*) from action_text_rich_texts where record_id = 1 and body not like '%<a%'" gives 1
    When I get "/rooms/1"
    Then the body contains "Docs at <a target=\"_blank\" href=\"https://example.com/a?b=1&amp;c=2\" rel=\"noopener noreferrer\">https://example.com/a?b=1&amp;c=2</a>. "
    And the body contains "Write to <a target=\"_blank\" href=\"mailto:ana@example.com\" rel=\"noopener noreferrer\">ana@example.com</a> "
    And the body contains "see <a target=\"_blank\" href=\"http://www.example.org\" rel=\"noopener noreferrer\">www.example.org</a> (soon)"

  Scenario: A link that is already one is not linked again, and a text that is only a word stays
    Given I sign in as "ana@example.com"
    When I post to "/rooms/1/messages" the form:
      | message[format] | html                                                                                  |
      | message[body]   | <p><a href="https://example.com/x">see https://example.com/x</a> and javascript:alert(1)</p> |
    And I get "/rooms/1"
    Then the body contains "<div id=\"presentation_message_1\"><p><a href=\"https://example.com/x\" rel=\"noopener noreferrer\">see https://example.com/x</a> and javascript:alert(1)</p></div>"

  Scenario: The Turbo Stream of a post shows the links too
    Given I sign in as "ana@example.com"
    And the request header "accept" is "text/vnd.turbo-stream.html"
    When I post to "/rooms/1/messages" the form:
      | message[body] | https://example.com |
    Then the status is 200
    And the body contains "<a target=\"_blank\" href=\"https://example.com\" rel=\"noopener noreferrer\">https://example.com</a>"

  Scenario: A code block survives the form, the page and a bot that reads it and writes it back
    Given I sign in as "ana@example.com"
    When I post to "/rooms/1/messages" the form:
      | message[format] | html                                                                                           |
      | message[body]   | <pre data-language="ruby"><code>puts 1 < 2 && "a"<br>puts :ok</code></pre> |
    Then the status is 302
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = '<pre data-language=\"ruby\"><code>puts 1 &lt; 2 &amp;&amp; \"a\"<br>puts :ok</code></pre>'" gives 1
    And the query "select count(*) from message_search_index where rowid = 1 and body like 'puts 1 < 2 && \"a\"%puts :ok'" gives 1
    When I get "/rooms/1"
    Then the body contains "<div id=\"presentation_message_1\"><pre data-language=\"ruby\"><code>puts 1 &lt; 2 &amp;&amp; \"a\"<br>puts :ok</code></pre></div>"
    When the browser has no cookies
    And I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages" the text ""
    Then the body contains "\"html\":\"<pre data-language=\\\"ruby\\\"><code>puts 1 &lt; 2 &amp;&amp; \\\"a\\\"<br>puts :ok</code></pre>\""
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "<pre data-language=\"ruby\"><code>puts 1 &lt; 2 &amp;&amp; \"a\"<br>puts :ok</code></pre>"
    Then the status is 201
    And the query "select count(*) from action_text_rich_texts where body = '<pre data-language=\"ruby\"><code>puts 1 &lt; 2 &amp;&amp; \"a\"<br>puts :ok</code></pre>'" gives 2
    When I send "PATCH" to "/rooms/1/3-aaaaBBBB1111/messages/2" the text "<pre data-language=\"ruby\"><code>puts 1 &lt; 2 &amp;&amp; \"a\"<br>puts :ok</code></pre>"
    Then the status is 200
    And the query "select count(*) from action_text_rich_texts where body = '<pre data-language=\"ruby\"><code>puts 1 &lt; 2 &amp;&amp; \"a\"<br>puts :ok</code></pre>'" gives 2

  Scenario: The language of a code block is a short name or nothing
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "<pre data-language=\"c++\">a</pre><pre data-language=\"x onclick=y\">b</pre><p data-language=\"ruby\">c</p>"
    Then the status is 201
    And the query "select count(*) from action_text_rich_texts where record_id = 1 and body = '<pre data-language=\"c++\">a</pre><pre>b</pre><p>c</p>'" gives 1

  Scenario: A bot's links are shown as links, and its JSON has the HTML as it was sent
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "<p>Build https://ci.example.com/42 passed</p>"
    And I send "GET" to "/rooms/1/3-aaaaBBBB1111/messages" the text ""
    Then the body contains "\"html\":\"<p>Build https://ci.example.com/42 passed</p>\""
    When I sign in as "bea@example.com"
    And I get "/rooms/1"
    Then the body contains "<p>Build <a target=\"_blank\" href=\"https://ci.example.com/42\" rel=\"noopener noreferrer\">https://ci.example.com/42</a> passed</p>"

  Scenario: A page of another site cannot post HTML
    Given I sign in as "ana@example.com"
    And the request header "sec-fetch-site" is "cross-site"
    When I post to "/rooms/1/messages" the form:
      | message[format] | html     |
      | message[body]   | <p>Hi</p> |
    Then the status is 403
    And the query "select count(*) from messages" gives 0

  Scenario: A visitor with no session cannot post HTML
    Given the browser has no cookies
    When I post to "/rooms/1/messages" the form:
      | message[format] | html     |
      | message[body]   | <p>Hi</p> |
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from messages" gives 0

  Scenario: A person who is not in a closed room gets 404 when posting HTML there
    Given a closed room "Secret" with the members "ana@example.com"
    And I sign in as "bea@example.com"
    When I post to "/rooms/2/messages" the form:
      | message[format] | html     |
      | message[body]   | <p>Hi</p> |
    Then the status is 404
    And the query "select count(*) from messages" gives 0

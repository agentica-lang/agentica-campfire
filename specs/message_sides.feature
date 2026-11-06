Feature: The side of a message
  In a room the messages of the person who looks are on one side and everybody else's on the other, as in a chat
  app. The HTML of a message is the same for every viewer (the live stream renders it once for all its subscribers), so
  it names its author with `data-creator-id` and says nothing of the side. The room page, which is made for one person
  (the page cache keys it by person), carries one `<style>` rule that sets the custom properties of the bubble for the
  messages of that person; the stylesheet does the rest. The first admin is Ana, user 1; Bea is user 2.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And the cable peer starts

  Scenario: The room page names the author of each message and sets apart the messages of the person who looks only
    When I post to "/rooms/1/messages" the form:
      | message[body] | From Ana |
    And I sign in as "bea@example.com"
    And I post to "/rooms/1/messages" the form:
      | message[body] | From Bea |
    And I get "/rooms/1"
    Then the body contains "data-message-id=\"1\" data-creator-id=\"1\">" 1 times
    And the body contains "data-message-id=\"2\" data-creator-id=\"2\">" 1 times
    And the body contains "<style>.thread [data-creator-id=\"2\"]{" 1 times
    And the body does not contain "<style>.thread [data-creator-id=\"1\"]{"
    When I sign in as "ana@example.com"
    And I get "/rooms/1"
    Then the body contains "<style>.thread [data-creator-id=\"1\"]{" 1 times
    And the body does not contain "<style>.thread [data-creator-id=\"2\"]{"
    When I get "/rooms/1/messages"
    Then the body contains "data-creator-id=\"" 2 times
    And the body does not contain "<style>"

  Scenario: The answer to a post and the broadcast to the room name the author and carry no side
    When I get "/rooms/1"
    And client "ana" connects with the cookies of the browser
    And client "ana" subscribes to the streams of the last page
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When I sign in as "bea@example.com"
    Given the request header "accept" is "text/vnd.turbo-stream.html, text/html"
    And the request header "sec-fetch-site" is "same-origin"
    When I post to "/rooms/1/messages" the form:
      | message[body]              | Streamed |
      | message[client_message_id] | s1       |
    Then the status is 200
    And the body contains "data-message-id=\"1\" data-creator-id=\"2\">" 1 times
    And the body does not contain "<style>"
    And client "ana" eventually receives a frame containing "data-message-id=\\\"1\\\" data-creator-id=\\\"2\\\">"

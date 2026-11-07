Feature: The stylesheet and the script
  Every page links one fingerprinted stylesheet, `/assets/campfire-DIGEST.css`, where DIGEST is the start of the SHA-256
  of the file (`public/assets/`, `CAMPFIRE_ASSETS_DIR`). It is served as `text/css` with the same bytes every time and
  kept for a year by any cache, and it is public: the sign-in page has to look right before anyone is signed in. The
  room page and every page with the sidebar also link the one script of the app, `/assets/campfire-DIGEST.js`, which sends
  the composer without a reload and keeps the page live; the pages of a visitor who is not signed in do not link it.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: The page links a stylesheet that is served as it was written
    When I get "/rooms/1"
    And I get the stylesheet that the page links
    Then the status is 200
    And the header "content-type" contains "text/css"
    And the header "cache-control" contains "immutable"
    And the body contains "{"
    And the body contains "--accent:"
    And the body does not contain "@use"
    And the body has the SHA-256 that starts with the digest in the name of the file
    When I remember the answer
    And I get "/rooms/1"
    And I get the stylesheet that the page links
    Then the answer is the one that I remembered

  Scenario: The room page links the script, served as it was written, and so does a page with the sidebar, but not a page of a visitor
    When I get "/rooms/1"
    Then the body does not contain "autofocus"
    When I get the script that the page links
    Then the status is 200
    And the header "content-type" contains "javascript"
    And the header "cache-control" contains "immutable"
    And the body contains "fetch("
    And the body contains "confirm_subscription"
    And the body contains "No messages here yet."
    And the body contains "IntersectionObserver"
    And the body contains "DateTimeFormat"
    And the body has the SHA-256 that starts with the digest in the name of the file
    When I get "/users"
    Then the body contains "<script src=\"/assets/campfire-" 1 times
    And the body contains "interactive-widget=resizes-content"
    When the browser has no cookies
    And I get "/session/new"
    Then the body does not contain "<script"

  Scenario: The page that edits a message links the same script, which has the keys of the composer and of the edit form
    Given the room 1 has 1 messages
    When I get "/rooms/1/messages/1/edit"
    Then the body contains "<script src=\"/assets/campfire-"
    And the body contains "<a href=\"/rooms/1\" data-cancel>Back to the room</a>"
    When I get the script that the page links
    Then the status is 200
    And the body contains "keydown"
    And the body contains "Escape"
    And the body contains "requestSubmit"
    And the body has the SHA-256 that starts with the digest in the name of the file

  Scenario: The stylesheet is served to a visitor who is not signed in, and nothing else is
    Given the browser has no cookies
    When I get "/session/new"
    And I get the stylesheet that the page links
    Then the status is 200
    When I get "/assets/missing.css"
    Then the status is 404
    And the body is "Not Found"
    When I get "/assets/"
    Then the status is 404

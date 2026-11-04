Feature: The stylesheet
  Every page links one fingerprinted stylesheet, `/assets/campfire-DIGEST.css`, where DIGEST is the start of the SHA-256
  of the file (`public/assets/`, `CAMPFIRE_ASSETS_DIR`). It is served as `text/css` with the same bytes every time and
  kept for a year by any cache, and it is public: the sign-in page has to look right before anyone is signed in.

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
    And the body has the SHA-256 that starts with the digest in the name of the stylesheet
    When I remember the answer
    And I get "/rooms/1"
    And I get the stylesheet that the page links
    Then the answer is the one that I remembered

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

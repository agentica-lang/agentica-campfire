Feature: Cache-Control of the pages
  A browser may keep an answer that has no `Cache-Control` and show it again after a deploy, with a link to an old
  stylesheet. So every HTML page and every redirect that does not say how it is cached gets Rails' default,
  `max-age=0, private, must-revalidate`: the browser asks again each time. An answer that says its own policy keeps it:
  the fingerprinted stylesheet and script are kept for a year, a page with a token is `no-store`, and a room page has
  the policy of its cache (page_cache.feature).

  Background:
    Given a fresh database
    And the app starts

  Scenario: The first-run page and the redirect to it are revalidated
    When I get "/"
    Then the status is 302
    And the header "cache-control" is "max-age=0, private, must-revalidate"
    When I get "/first_run"
    Then the status is 200
    And the header "cache-control" is "max-age=0, private, must-revalidate"

  Scenario: The sign-in page, a redirect and a refused sign-in are revalidated
    Given the first admin exists
    When the browser has no cookies
    And I get "/session/new"
    Then the status is 200
    And the body contains "<link rel=\"stylesheet\""
    And the header "cache-control" is "max-age=0, private, must-revalidate"
    When I get "/"
    Then the status is 302
    And the header "location" is "/session/new"
    And the header "cache-control" is "max-age=0, private, must-revalidate"
    When I post to "/session" the form:
      | email_address | nobody@example.com |
      | password      | wrong password here |
    Then the status is 422
    And the header "cache-control" is "max-age=0, private, must-revalidate"

  Scenario: The stylesheet and the script are still kept for a year, and a page with a token is still not stored
    Given the first admin exists
    When I get "/rooms/1"
    And I get the stylesheet that the page links
    Then the header "cache-control" contains "immutable"
    And the header "cache-control" does not contain "must-revalidate"
    When I get "/rooms/1"
    And I get the script that the page links
    Then the header "cache-control" contains "immutable"
    When I sign in as "ana@example.com"
    And I get "/users"
    Then the header "cache-control" is "no-store"

  Scenario: A HEAD request gets the same header as the GET
    Given the first admin exists
    When the browser has no cookies
    And I send a HEAD to "/session/new"
    Then the status is 200
    And the header "cache-control" is "max-age=0, private, must-revalidate"

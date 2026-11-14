Feature: The installable web app
  As Rails Campfire (`PwaController`, `Accounts::LogosController`), the app has a manifest at `/webmanifest.json` named
  after the account, a service worker at `/service-worker.js` and the icon of the account at `/account/logo` (512
  pixels, or 192 with `?size=small`), the stock icon of Rails until an account can have its own. The three need no
  sign-in, since a browser fetches them without the cookie of a session. Every page links the manifest and the icon. The
  service worker keeps the fingerprinted stylesheet and script only: no page, form, API or `/cable` answer.

  Background:
    Given a fresh database
    And the app starts

  Scenario: Before the first run the manifest names the app Campfire, and needs no sign-in
    When I get "/webmanifest.json"
    Then the status is 200
    And the header "content-type" contains "application/json"
    And the body contains "\"name\":\"Campfire\""
    And the body contains "\"start_url\":\"/\""
    And the body contains "\"display\":\"standalone\""
    And the body contains "\"src\":\"/account/logo?size=small\""
    And the body contains "\"sizes\":\"512x512\""

  Scenario: The manifest names the app after the account
    Given the first admin exists
    When I run the sql "update accounts set name = 'Ops Chat'"
    And the browser has no cookies
    And I get "/webmanifest.json"
    Then the status is 200
    And the body contains "\"name\":\"Ops Chat\""

  Scenario: The icon of the account is a PNG in two sizes, kept by any cache for five minutes
    When I get "/account/logo"
    Then the status is 200
    And the header "content-type" contains "image/png"
    And the header "cache-control" is "max-age=300, public, stale-while-revalidate=604800"
    And the header "content-length" is "405666"
    And the body is a PNG image
    When I get "/account/logo?size=small"
    Then the status is 200
    And the header "content-length" is "61306"
    And the body is a PNG image

  Scenario: The service worker needs no sign-in and keeps only the stylesheet and the script
    When I get "/service-worker.js"
    Then the status is 200
    And the header "content-type" contains "javascript"
    And the header "cache-control" is "no-cache"
    And the body contains "const SHELL = [\"/assets/campfire-"
    And the body contains "addEventListener(\"fetch\""
    And the body does not contain "/cable"
    And the body does not contain "/rooms"

  Scenario: Every page links the manifest and the icon, and the script registers the service worker
    When I get "/first_run"
    Then the body contains "<link rel=\"manifest\" href=\"/webmanifest.json\">"
    And the body contains "<link rel=\"icon\" href=\"/account/logo?size=small\" type=\"image/png\">"
    Given the first admin exists
    When I get "/rooms/1"
    And I get the script that the page links
    Then the body contains "/service-worker.js"

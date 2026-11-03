Feature: Home page and health check
  The app listens on the host and port of its config (the specs use 127.0.0.1 and port 0, a free port). `GET /` is the
  home page, an HTML page made by an EAG template that escapes what it inserts, and `GET /health` says that the
  process serves, for a load balancer or a container check (database.feature checks the schema version it reports).

  Background:
    Given the app listens on a free port

  Scenario: The home page is HTML with the name of the app
    When I get "/"
    Then the status is 200
    And the header "content-type" is "text/html; charset=utf-8"
    And the body contains "<title>Campfire</title>"
    And the body contains "<h1>Campfire</h1>"

  Scenario: The health check says the app is up
    When I get "/health"
    Then the status is 200
    And the header "content-type" is "application/json"
    And the body contains "\"status\":\"ok\""

  Scenario: A path with no route is a 404
    When I get "/nothing"
    Then the status is 404

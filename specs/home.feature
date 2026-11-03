Feature: Home page and health check
  The app listens on the host and port of its config (the specs use 127.0.0.1 and port 0, a free port). `GET /` is the
  home page for a signed-in person, an HTML page made by an EAG template that escapes what it inserts (auth.feature has
  the visitor who is not signed in). `GET /health` says that the process serves, for a load balancer or a container
  check, and needs no sign-in (database.feature checks the schema version it reports).

  Background:
    Given a fresh database
    And the app starts

  Scenario: The home page is HTML with the name of the app and a way to sign out
    Given the first admin exists
    When I get "/"
    Then the status is 200
    And the header "content-type" is "text/html; charset=utf-8"
    And the body contains "<title>Campfire</title>"
    And the body contains "<h1>Campfire</h1>"
    And the body contains "<form method=\"post\" action=\"/sign_out\">"

  Scenario: The health check says the app is up
    When I get "/health"
    Then the status is 200
    And the header "content-type" is "application/json"
    And the body contains "\"status\":\"ok\""

  Scenario: A path with no route is a 404 for a signed-in person
    Given the first admin exists
    When I get "/nothing"
    Then the status is 404

Feature: Signing in on another device
  As Rails Campfire (`Sessions::TransfersController`, `QrCodeController`), a person who is signed in can make a link
  that signs another browser in as them, shown with its QR code. Unlike Rails, a link works once and for 15 minutes, and
  the server keeps only a hash of it, in memory. Opening the link shows a button; the button (`PUT`) signs in and goes
  home, and a link that does not work, whatever the reason, is a 400. `/qr_code/ID` draws the Base64url text ID as an
  SVG. Both need no sign-in; making a link does. The expiry is in `test/transfers_test.agc`.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: A link signs a second browser in, once
    When I get "/users/me/profile"
    Then the body contains "<form method=\"post\" action=\"/session/transfers\">"
    When I post nothing to "/session/transfers"
    Then the status is 200
    And the header "cache-control" is "no-store"
    And the body contains "<svg xmlns=\"http://www.w3.org/2000/svg\""
    And the body contains "It works once, for 15 minutes."
    When I remember the sign-in link of the page
    And the browser has no cookies
    And I get the sign-in link that I remembered
    Then the status is 200
    And the header "cache-control" is "no-store"
    And the body contains "<input name=\"_method\" type=\"hidden\" value=\"put\">"
    When I get "/users/me/profile"
    Then the status is 302
    When I post to the sign-in link that I remembered the form:
      | _method | put |
    Then the status is 302
    And the header "location" is "/"
    And the header "set-cookie" contains "session_token="
    When I get "/users/me/profile"
    Then the status is 200
    And the body contains "value=\"ana@example.com\""
    And the query "select count(*) from sessions where user_id = 1" gives 2
    When the browser has no cookies
    And I send a PUT to the sign-in link that I remembered
    Then the status is 400
    And the header "set-cookie" does not contain "session_token="

  Scenario: A link that was never made, and a link of a person who has been deactivated since, are a 400
    When I send a PUT to "/session/transfers/0123456789abcdef"
    Then the status is 400
    When I post nothing to "/session/transfers"
    And I remember the sign-in link of the page
    And I run the sql "update users set status = 1 where id = 1"
    And the browser has no cookies
    And I send a PUT to the sign-in link that I remembered
    Then the status is 400
    And the header "set-cookie" does not contain "session_token="

  Scenario: Making a link needs a sign-in
    When the browser has no cookies
    And I post nothing to "/session/transfers"
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: A page of another site can neither make a link nor use one
    When I post nothing to "/session/transfers"
    And I remember the sign-in link of the page
    And the browser has no cookies
    And the request header "sec-fetch-site" is "cross-site"
    And I send a PUT to the sign-in link that I remembered
    Then the status is 403
    When the request header "sec-fetch-site" is "same-origin"
    And I send a PUT to the sign-in link that I remembered
    Then the status is 302
    When the request header "sec-fetch-site" is "cross-site"
    And I post nothing to "/session/transfers"
    Then the status is 403

  Scenario: A POST to a link with another method is a 405
    When I post nothing to "/session/transfers"
    And I remember the sign-in link of the page
    And I post to the sign-in link that I remembered the form:
      | _method | delete |
    Then the status is 405
    And the header "allow" is "GET, HEAD, POST, PUT"

  Scenario: The QR code of a Base64url text is an SVG kept by any cache, and a bad text is a 400
    When the browser has no cookies
    And I get "/qr_code/aHR0cHM6Ly9jYW1wZmlyZS5leGFtcGxlLmNvbS8"
    Then the status is 200
    And the header "content-type" contains "image/svg+xml"
    And the header "cache-control" is "max-age=31536000, public"
    And the body starts with "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 37 37\""
    When I get "/qr_code/not*base64"
    Then the status is 400
    When I get "/qr_code/eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eA"
    Then the status is 400

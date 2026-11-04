Feature: The join link
  An administrator sees the link of the account on the people page, starting with the public address of the app, and
  can make a new one, after which the old link is a 404. The link on the page is the one that works. The first admin is
  Ana, user 1.

  Background:
    Given a fresh database
    And the app is given the public address "https://campfire.test"
    And the app starts
    And the first admin exists
    And a member "Bea" with the email "bea@example.com" exists
    And I run the sql "update accounts set join_code = 'aaaa-bbbb-cccc'"

  Scenario: The link starts with the public address and is kept out of caches and referrers
    When I get "/users"
    Then the status is 200
    And the body contains "https://campfire.test/join/aaaa-bbbb-cccc"
    And the header "cache-control" is "no-store"
    And the header "referrer-policy" is "no-referrer"

  Scenario: The link on the page lets a new person in
    When I get "/users"
    And I remember the join link
    And the browser has no cookies
    And I get the join link that I remembered
    Then the status is 200
    When I submit the join form of the page with:
      | name     | Cy                    |
      | email    | cy@example.com        |
      | password | another long password |
    Then the status is 302
    And the query "select count(*) from users where email = 'cy@example.com' and active = 1" gives 1
    And the query "select count(*) from memberships where user_id = 3 and room_id = 1" gives 1

  Scenario: A new link replaces the old one, which stops working
    When I get "/users"
    And I remember the join link
    And I submit the form of the page that posts to "/account/join_code"
    Then the status is 302
    And the header "location" is "/users"
    And the query "select count(*) from accounts where join_code <> 'aaaa-bbbb-cccc'" gives 1
    When I get "/users"
    Then the body does not contain "aaaa-bbbb-cccc"
    And the join link of the page is not the one that I remembered
    When the browser has no cookies
    And I get the join link that I remembered
    Then the status is 404
    When I post to the join link that I remembered the form:
      | name     | Cy                    |
      | email    | cy@example.com        |
      | password | another long password |
    Then the status is 404
    And the query "select count(*) from users" gives 2
    When I sign in as "ana@example.com"
    And I get "/users"
    And I remember the join link
    And the browser has no cookies
    And I get the join link that I remembered
    Then the status is 200

  Scenario: A page of another site cannot make a new link
    Given the request header "sec-fetch-site" is "cross-site"
    When I post nothing to "/account/join_code"
    Then the status is 403
    And the query "select count(*) from accounts where join_code = 'aaaa-bbbb-cccc'" gives 1

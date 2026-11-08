Feature: Avatars
  `GET /users/TOKEN/avatar` is the link of upstream Campfire: TOKEN is `user.signed_id(purpose: :avatar)` that Rails made
  from `SECRET_KEY_BASE` (the specs use the key of `test/signed_id_test.agc`). A person who has an avatar gets the file
  that Active Storage made for it, the WebP variant `:square`, as it is on the disk (`CAMPFIRE_STORAGE_DIR`, the
  `xx/yy/KEY` folders of the Disk service); anybody else gets an SVG with their initials, as upstream does. A token
  that does not verify is a 404 like any missing page. The rows and files are what Rails 8.0.2 wrote for the avatar of
  user 1 (`specs/fixtures/rails/make_avatar.sh`). The first admin, Ana, is user 1.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: The avatar is the stored WebP variant, the same bytes every time
    Given the avatar that Rails stored for the user 1
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 200
    And the header "content-type" is "image/webp"
    And the header "cache-control" is "private, max-age=1800, stale-while-revalidate=604800"
    And the body is a WebP image
    And the body is the stored variant of the avatar of the user 1
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the body is the stored variant of the avatar of the user 1
    When the request header "if-none-match" is the header "etag" of the answer
    And I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 304
    And the body is ""
    And the header "cache-control" is "private, max-age=1800, stale-while-revalidate=604800"

  Scenario: A person without an avatar gets their initials
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 200
    And the header "content-type" contains "image/svg+xml"
    And the header "cache-control" contains "private"
    And the body starts with "<svg"
    And the body contains "fill=\"#BF7C2A\""
    And the body contains ">A</text>"

  Scenario: A person whose avatar has no variant yet gets the original image, not initials
    Given the avatar that Rails stored for the user 1
    And I run the sql "delete from active_storage_attachments where record_type = 'ActiveStorage::VariantRecord'"
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 200
    And the header "content-type" is "image/jpeg"
    And the body is the stored original of the avatar of the user 1

  Scenario: An original that is not a plain image is not sent
    Given the avatar that Rails stored for the user 1
    And I run the sql "delete from active_storage_attachments where record_type = 'ActiveStorage::VariantRecord'"
    And I run the sql "update active_storage_blobs set content_type = 'image/svg+xml' where id = 1"
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the header "content-type" contains "image/svg+xml"
    And the body starts with "<svg"
    And the body contains ">A</text>"

  Scenario: A variant whose file is gone is not found, and nobody is told that it exists
    Given the avatar that Rails stored for the user 1
    And I run the sql "update active_storage_blobs set key = 'zzzzzzzzzzzz' where id = 2"
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 404
    And the body is "Not Found"

  Scenario: What the database says is kept for its version, so a new picture and a removed one show at once
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the body starts with "<svg"
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the body starts with "<svg"
    Given the avatar that Rails stored for the user 1
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 200
    And the header "content-type" is "image/webp"
    And the body is the stored variant of the avatar of the user 1
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the body is the stored variant of the avatar of the user 1
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b86/avatar"
    Then the status is 404
    When I post to "/users/me/avatar" the form:
      | _method | delete |
    And I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 200
    And the body starts with "<svg"
    Given the browser has no cookies
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 302
    And the header "location" is "/session/new"

  Scenario: A file that goes from the disk is a 404 even when the answer was kept
    Given the avatar that Rails stored for the user 1
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    And I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 200
    When I delete the stored file "x1s3j8autb7671fkjsjfwutj3z3z"
    And I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 404
    And the body is "Not Found"

  Scenario: The cache buster of the links (`?v=`) changes nothing in the answer
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar?v=20261104182129614026"
    Then the status is 200
    And the body starts with "<svg"

  Scenario Outline: A token that does not verify is not found
    When I get "/users/<token>/avatar"
    Then the status is 404
    And the body is "Not Found"

  Examples:
    | token |
    | nonsense |
    | eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b86 |
    | eyJfcmFpbHMiOnsiZGF0YSI6NDIsInB1ciI6InVzZXIvYXZhdGFyIn19--b6171f5a67a8d5310d4801c106c630c5d77959c1ee6c8002cfc33fafcb656df5 |
    | eyJfcmFpbHMiOnsiZGF0YSI6NDIsInB1ciI6InVzZXIifX0--f9175aeb4fb9058aaec13a9aa8b3a59b883282b429cc34f41bb194f4aed23975 |
    | eyJfcmFpbHMiOnsiZGF0YSI6NDIsInB1ciI6InVzZXIvYXZhdGFyIn19--ef87430eae10b22fca259ec0b28b3af3123583239cb94a098ccffaafadf8c97e |

  Scenario: The avatar needs a sign-in
    Given the browser has no cookies
    When I get "/users/eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85/avatar"
    Then the status is 302
    And the header "location" is "/session/new"

Feature: Attachments
  A message may carry a file, posted as Rails Campfire's uploader posts it: a `multipart/form-data` form with the file in
  `message[attachment]` and no text. The file is stored as Active Storage's Disk service stores it (a blob row, an
  attachment row of the message and the file at `xx/yy/KEY` of `CAMPFIRE_STORAGE_DIR`), with the type that its bytes
  and its name say, never the one the client said. It is downloaded at `/rooms/ID/messages/MESSAGE/attachment`, by the
  people of the room only: an image whose bytes are of its type is shown, anything else is a download, and every answer
  has `nosniff` and a policy that runs nothing. Deleting the message deletes the file. Ana, the first admin, is user 1,
  and "All Talk" is room 1.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario: A member posts a file to a room they are in, and it is stored as Active Storage stores it
    When I upload to "/rooms/1/messages" the file "notes.txt" of the type "application/x-whatever" that holds "hello"
    Then the status is 302
    And the header "location" is "/rooms/1"
    And the query "select count(*) from active_storage_blobs where filename = 'notes.txt' and content_type = 'text/plain' and byte_size = 5 and service_name = 'local' and length(key) = 28" gives 1
    And the query "select count(*) from active_storage_attachments where name = 'attachment' and record_type = 'Message' and record_id = 1" gives 1
    And the query "select count(*) from message_search_index where rowid = 1 and body = 'notes.txt'" gives 1
    And the storage folder holds 1 files
    When I get "/rooms/1"
    Then the body contains "<a href=\"/rooms/1/messages/1/attachment\" download>notes.txt</a>"

  Scenario: A file that is not an image is downloaded, with its type, its name and nosniff
    Given I upload to "/rooms/1/messages" the file "notes.txt" of the type "text/plain" that holds "hello"
    When I get "/rooms/1/messages/1/attachment"
    Then the status is 200
    And the body is "hello"
    And the header "content-type" is "text/plain"
    And the header "content-disposition" is "attachment; filename=\"notes.txt\""
    And the header "x-content-type-options" is "nosniff"
    And the header "content-security-policy" is "default-src 'none'; sandbox"
    And the header "cache-control" is "private, no-cache"
    Given the request header "range" is "bytes=1-2"
    When I get "/rooms/1/messages/1/attachment"
    Then the status is 206
    And the body is "el"

  Scenario: An image is found by its bytes and shown inline
    When I upload to "/rooms/1/messages" a PNG image named "pixel" of the type "application/octet-stream"
    Then the status is 302
    And the query "select count(*) from active_storage_blobs where content_type = 'image/png'" gives 1
    When I get "/rooms/1/messages/1/attachment"
    Then the status is 200
    And the header "content-type" is "image/png"
    And the header "content-disposition" does not contain "attachment"
    And the header "x-content-type-options" is "nosniff"
    And the body is a PNG image

  Scenario Outline: A file that a browser could run is never served inline, whatever the client said
    When I upload to "/rooms/1/messages" the file "<name>" of the type "<said>" that holds "<script>alert(1)</script>"
    Then the status is 302
    And the query "select count(*) from active_storage_blobs where content_type = '<stored>'" gives 1
    When I get "/rooms/1/messages/1/attachment"
    Then the status is 200
    And the header "content-type" is "application/octet-stream"
    And the header "content-disposition" contains "attachment"
    And the header "x-content-type-options" is "nosniff"

    Examples:
      | name      | said          | stored                   |
      | page.html | text/html     | text/html                |
      | logo.svg  | image/svg+xml | image/svg+xml            |
      | fake.png  | image/png     | application/octet-stream |
      | run.js    | image/gif     | text/javascript          |

  Scenario: A stored image whose bytes are not of its type is a download
    Given I upload to "/rooms/1/messages" the file "notes.txt" of the type "text/plain" that holds "<html>"
    And I run the sql "update active_storage_blobs set content_type = 'image/png'"
    When I get "/rooms/1/messages/1/attachment"
    Then the header "content-disposition" contains "attachment"
    And the header "content-type" is "image/png"

  Scenario: The name of the file is never a path
    When I upload to "/rooms/1/messages" the file "../../../etc/passwd" of the type "text/plain" that holds "x"
    Then the status is 302
    And the query "select count(*) from active_storage_blobs where filename = 'passwd'" gives 1
    And the storage folder holds 1 files

  Scenario: Somebody who is not in the room cannot post a file to it nor download one, and is told nothing
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret" with the members "ana@example.com"
    And I upload to "/rooms/2/messages" the file "plan.txt" of the type "text/plain" that holds "secret"
    And I sign in as "bea@example.com"
    When I upload to "/rooms/2/messages" the file "mine.txt" of the type "text/plain" that holds "x"
    Then the status is 404
    And the query "select count(*) from active_storage_blobs" gives 1
    And the query "select count(*) from messages" gives 1
    And the storage folder holds 1 files
    When I get "/rooms/2/messages/1/attachment"
    Then the status is 404
    And the body does not contain "secret"
    When I get "/rooms/1/messages/1/attachment"
    Then the status is 404
    When I get "/rooms/2/messages/99/attachment"
    Then the status is 404

  Scenario: A message with no file has nothing to download
    Given I post to "/rooms/1/messages" the form:
      | message[body] | Just words |
    When I get "/rooms/1/messages/1/attachment"
    Then the status is 404

  Scenario: Deleting the message deletes its file
    Given I upload to "/rooms/1/messages" the file "notes.txt" of the type "text/plain" that holds "hello"
    When I send a DELETE to "/rooms/1/messages/1"
    Then the status is 302
    And the query "select count(*) from active_storage_blobs" gives 0
    And the query "select count(*) from active_storage_attachments" gives 0
    And the storage folder holds 0 files

  Scenario: Deleting the room deletes the files of its messages
    Given a closed room "Files" with the members "ana@example.com"
    And I upload to "/rooms/2/messages" the file "a.txt" of the type "text/plain" that holds "a"
    And I upload to "/rooms/2/messages" the file "b.txt" of the type "text/plain" that holds "b"
    When I send a DELETE to "/rooms/2"
    Then the query "select count(*) from rooms where id = 2" gives 0 within 5000 milliseconds
    And the query "select count(*) from active_storage_blobs" gives 0
    And the storage folder holds 0 files

  Scenario: A visitor with no session and a page of another site post no file
    Given the browser has no cookies
    When I upload to "/rooms/1/messages" the file "notes.txt" of the type "text/plain" that holds "x"
    Then the status is 302
    And the header "location" is "/session/new"
    When I get "/rooms/1/messages/1/attachment"
    Then the status is 302
    And the header "location" is "/session/new"
    Given I sign in as "ana@example.com"
    And the request header "sec-fetch-site" is "cross-site"
    When I upload to "/rooms/1/messages" the file "notes.txt" of the type "text/plain" that holds "x"
    Then the status is 403
    And the query "select count(*) from messages" gives 0
    And the storage folder holds 0 files

  Scenario: The cookie of a session that was ended posts no file
    Given the browser saves a copy of its cookies
    And I post nothing to "/sign_out"
    When the browser restores its saved cookies
    And the request header "content-type" is "multipart/form-data; boundary=x"
    And I send "POST" to "/rooms/1/messages" the text "--x"
    Then the status is 302
    And the header "location" is "/session/new"
    When I upload to "/rooms/1/messages" the file "notes.txt" of the type "text/plain" that holds "x"
    Then the status is 302
    And the header "location" is "/session/new"
    And the query "select count(*) from messages" gives 0
    And the storage folder holds 0 files

  Scenario: A multipart body to any other path is refused before it is read
    When I upload to "/session" the file "notes.txt" of the type "text/plain" that holds "x"
    Then the status is 415
    Given the request header "content-type" is "multipart/form-data; boundary=x"
    When I send "POST" to "/first_run" the text "--x"
    Then the status is 415
    When I send "POST" to "/rooms/1/3-aaaaBBBB1111/messages" the text "--x"
    Then the status is 415
    And the storage folder holds 0 files

  Scenario: The start empties the folder of the uploads
    Given a crash left a file in the folder of the uploads
    When the app restarts
    Then the storage folder holds 0 files

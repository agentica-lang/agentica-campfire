Feature: Direct uploads to S3
  With `CAMPFIRE_STORAGE_SERVICE=s3` the browser puts a file in the bucket itself: the app makes the blob row and
  signs the URLs (`POST /rails/active_storage/direct_uploads`, as Active Storage's own direct upload does), and the
  message names the blob by its key. The file is shown by a redirect to a signed `GET`, after the check of the room.
  The bucket is `fixtures/s3_stub.py`, which checks every signature with code of its own. Ana, the first admin, is user
  1, and "All Talk" is room 1.

  Background:
    Given an S3 server
    And a fresh database
    And the app starts
    And the first admin exists

  Scenario: A file goes to the bucket, is attached by its key and is shown by a redirect
    When I ask for a direct upload of "pixel.png" of the type "application/octet-stream" and 70 bytes
    And the browser puts a file of 70 bytes that starts with "89504e470d0a1a0a" at the URLs of the answer
    And I post to "/rooms/1/messages" the message with the direct upload of the answer
    Then the status is 302
    And the query "select count(*) from active_storage_blobs where filename = 'pixel.png' and content_type = 'image/png' and byte_size = 70 and service_name = 's3' and length(key) = 28" gives 1
    And the query "select count(*) from active_storage_attachments where name = 'attachment' and record_type = 'Message' and record_id = 1" gives 1
    And the storage folder holds 0 files
    When I get "/rooms/1/messages/1/attachment"
    Then the status is 302
    And the header "cache-control" is "private, no-cache"
    And the header "location" contains "X-Amz-Signature="
    And the header "location" contains "response-content-type=image%2Fpng"
    And the location of the answer gives 70 bytes of the type "image/png"

  Scenario: A file that is not an image is a download with its name
    When I ask for a direct upload of "notes.txt" of the type "text/plain" and 5 bytes
    And the browser puts a file of 5 bytes that starts with "68656c6c6f" at the URLs of the answer
    And I post to "/rooms/1/messages" the message with the direct upload of the answer
    And I get "/rooms/1/messages/1/attachment"
    Then the header "location" contains "response-content-disposition=attachment%3B%20filename%3D%22notes.txt%22"
    And the location of the answer gives 5 bytes of the type "text/plain"

  Scenario: The form of the room says where to ask for the URLs
    When I get "/rooms/1"
    Then the body contains "data-direct-uploads=\"/rails/active_storage/direct_uploads\""

  Scenario: A name that is not ASCII is sent as a filename* too
    When I ask for a direct upload of "résumé.txt" of the type "text/plain" and 5 bytes
    And the browser puts a file of 5 bytes that starts with "68656c6c6f" at the URLs of the answer
    And I post to "/rooms/1/messages" the message with the direct upload of the answer
    And I get "/rooms/1/messages/1/attachment"
    Then the header "location" contains "filename%3D%22r_sum_.txt%22%3B%20filename%2A%3DUTF-8%27%27r%25C3%25A9sum%25C3%25A9.txt"

  Scenario: A big file goes in parts, which the app completes when the message is posted
    When I ask for a direct upload of "big.bin" of the type "application/octet-stream" and 20971520 bytes
    Then the direct upload has 2 parts
    When the browser puts a file of 20971520 bytes that starts with "00" at the URLs of the answer
    And I post to "/rooms/1/messages" the message with the direct upload of the answer
    Then the status is 302
    When I get "/rooms/1/messages/1/attachment"
    Then the location of the answer gives 20971520 bytes of the type "application/octet-stream"

  Scenario: A file that comes in the form goes to the bucket from the app
    When I upload to "/rooms/1/messages" the file "notes.txt" of the type "text/plain" that holds "hello"
    Then the status is 302
    And the query "select count(*) from active_storage_blobs where service_name = 's3' and byte_size = 5" gives 1
    And the storage folder holds 0 files
    When I get "/rooms/1/messages/1/attachment"
    Then the location of the answer gives 5 bytes of the type "text/plain"

  Scenario: Only the people of the room are sent to the file
    Given a member "Bea" with the email "bea@example.com" exists
    And a closed room "Secret" with the members "ana@example.com"
    And I ask for a direct upload of "plan.txt" of the type "text/plain" and 6 bytes
    And the browser puts a file of 6 bytes that starts with "736563726574" at the URLs of the answer
    And I post to "/rooms/2/messages" the message with the direct upload of the answer
    When I sign in as "bea@example.com"
    And I get "/rooms/2/messages/1/attachment"
    Then the status is 404
    And the header "location" is ""

  Scenario: Deleting the room deletes the objects of its messages
    Given a closed room "Files" with the members "ana@example.com"
    And I ask for a direct upload and put 5 bytes that start with "68656c6c6f"
    And I post to "/rooms/2/messages" the message with the direct upload of the answer
    When I send a DELETE to "/rooms/2"
    Then the query "select count(*) from active_storage_blobs" gives 0 within 5000 milliseconds
    And the S3 server saw a DELETE of the object of the direct upload within 5 seconds

  Scenario: A blob that is not the person's, or whose file is not there, is not attached
    Given a member "Bea" with the email "bea@example.com" exists
    When I ask for a direct upload of "notes.txt" of the type "text/plain" and 5 bytes
    And I post to "/rooms/1/messages" the message with the direct upload of the answer
    Then the status is 422
    And the body contains "did not arrive whole"
    And the query "select count(*) from active_storage_attachments" gives 0
    When the browser puts a file of 5 bytes that starts with "68656c6c6f" at the URLs of the answer
    And I sign in as "bea@example.com"
    And I post to "/rooms/1/messages" the message with the direct upload of the answer
    Then the status is 422
    And the body contains "not there any more"
    And the query "select count(*) from active_storage_attachments" gives 0

  Scenario: An object that is not as big as the person said is refused when the message is posted
    Given I ask for a direct upload and put 5 bytes that start with "68656c6c6f"
    And I run the sql "update active_storage_blobs set byte_size = 6"
    When I post to "/rooms/1/messages" the message with the direct upload of the answer
    Then the status is 422
    And the body contains "did not arrive whole"
    And the query "select count(*) from messages" gives 0

  Scenario: Parts that are not those of the announced size are refused when the message is posted
    Given I ask for a direct upload and put 20971520 bytes that start with "00"
    And I run the sql "update active_storage_blobs set byte_size = 20971521"
    When I post to "/rooms/1/messages" the message with the direct upload of the answer
    Then the status is 422
    And the body contains "did not arrive whole"
    And the query "select count(*) from messages" gives 0

  Scenario: A part that the bucket refuses leaves an upload that cannot be posted
    Given the S3 server refuses the part 2
    When I ask for a direct upload of "big.bin" of the type "application/octet-stream" and 20971520 bytes
    And the browser puts the parts of a file of 20971520 bytes, and the part 2 is refused
    And I post to "/rooms/1/messages" the message with the direct upload of the answer
    Then the status is 422
    And the body contains "did not arrive whole"
    And the query "select count(*) from messages" gives 0

  Scenario: A person whose sessions ended (a ban) is given no URLs
    Given a member "Bea" with the email "bea@example.com" exists
    And I sign in as "bea@example.com"
    And I run the sql "delete from sessions where user_id = 2"
    When I ask for a direct upload of "notes.txt" of the type "text/plain" and 5 bytes
    Then the direct upload is answered with the status 302
    And the query "select count(*) from active_storage_blobs" gives 0

  Scenario: A file of the wrong size is refused when it is asked for
    When I ask for a direct upload of "empty.txt" of the type "text/plain" and 0 bytes
    Then the direct upload is refused as "The file is empty."
    When I ask for a direct upload of "huge.bin" of the type "text/plain" and 104857601 bytes
    Then the direct upload is refused as "the most is 100 MB"

  Scenario: Deleting the message deletes the object
    Given I ask for a direct upload and put 5 bytes that start with "68656c6c6f"
    And I post to "/rooms/1/messages" the message with the direct upload of the answer
    When I send a DELETE to "/rooms/1/messages/1"
    Then the S3 server saw a DELETE of the object of the direct upload

  Scenario: An upload that nobody posted is deleted a day later
    Given I ask for a direct upload and put 5 bytes that start with "68656c6c6f"
    When I run the sql "update active_storage_blobs set created_at = strftime('%Y-%m-%d %H:%M:%f000', 'now', '-2 days')"
    And the app restarts
    Then the S3 server saw a DELETE of the object of the direct upload within 10 seconds
    And the query "select count(*) from active_storage_blobs" gives 0

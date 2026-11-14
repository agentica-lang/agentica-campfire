Feature: Previews of attachments and the lightbox
  A message's image is shown in the room, and a video gets a player, as `Message::Attachment` of Rails Campfire shows
  them. The size of an image comes from its header when it is posted (no pixel is decoded) and is stored in the blob's
  metadata, as Active Storage's analyzer stores it; the page sizes the image to fit 1200 by 800 and shows it at half
  that. An image over 25 million pixels (Rails allows 250 million, as it shows a thumbnail), or one whose header cannot be read, is a link to download, as is any other
  file. A click on a preview opens the lightbox of the page, which has the link that downloads the file
  (`?disposition=attachment`). There is no server-side thumbnail and no video poster: the browser sizes the image. Ana,
  the first admin, is user 1, and "All Talk" is room 1.

  Background:
    Given a fresh database
    And the app starts
    And the first admin exists

  Scenario Outline: An image is shown at half the size that fits the preview box, and opens in the lightbox
    When I upload to "/rooms/1/messages" the file "<name>" of the type "image/png" with the bytes "<bytes>"
    Then the status is 302
    And the query "select json_extract(metadata, '$.width') || 'x' || json_extract(metadata, '$.height') from active_storage_blobs" gives the text "<stored>"
    When I get "/rooms/1"
    Then the body contains "<a href=\"/rooms/1/messages/1/attachment\" class=\"attachment\" data-lightbox data-download=\"/rooms/1/messages/1/attachment?disposition=attachment\"><img src=\"/rooms/1/messages/1/attachment\" width=\"<width>\" height=\"<height>\" alt=\"<name>\" loading=\"lazy\"></a>"
    And the body contains "<dialog class=\"lightbox\""

    Examples:
      | name      | bytes                                                                                              | stored    | width | height |
      | small.png | 89504e470d0a1a0a0000000d4948445200000280000001e00806000000                                         | 640x480   | 320   | 240    |
      | wide.png  | 89504e470d0a1a0a0000000d4948445200000960000006400806000000                                         | 2400x1600 | 600   | 400    |
      | photo.jpg | ffd8ffe100224578696600004d4d002a00000008000101120003000000010006000000000000ffc0001108006400c803 | 100x200   | 50    | 100    |

  Scenario Outline: An image over the pixel cap or with no readable header is posted without a preview
    When I upload to "/rooms/1/messages" the file "<name>" of the type "image/png" with the bytes "<bytes>"
    Then the status is 302
    And the query "select count(*) from messages" gives 1
    And the query "select content_type || ' ' || coalesce(json_extract(metadata, '$.width') || 'x' || json_extract(metadata, '$.height'), 'no size') from active_storage_blobs" gives the text "<stored>"
    When I get "/rooms/1"
    Then the body contains "<a href=\"/rooms/1/messages/1/attachment\" download><name></a>"
    And the body does not contain "data-lightbox"

    Examples:
      | name      | bytes                                                        | stored                 |
      | huge.webp | 5249464600000000574542505650385800000000000000001f4e00973a00 | image/webp 20000x15000 |
      | cut.png   | 89504e470d0a1a0a0000000d49484452                             | image/png no size      |
      | big.png   | 89504e470d0a1a0a0000000d4948445200001770000013880806000000   | image/png 6000x5000    |
      | bomb.png  | 89504e470d0a1a0a0000000d49484452c0000000c00000000806000000   | image/png no size      |

  Scenario: A video gets a player, and is still sent as a download with nosniff
    When I upload to "/rooms/1/messages" the file "clip.mp4" of the type "application/octet-stream" with the bytes "000000186674797069736f6d0000020069736f6d69736f32"
    Then the query "select content_type from active_storage_blobs" gives the text "video/mp4"
    When I get "/rooms/1"
    Then the body contains "<video src=\"/rooms/1/messages/1/attachment\" class=\"attachment\" controls preload=\"metadata\" title=\"clip.mp4\"></video>"
    When I get "/rooms/1/messages/1/attachment"
    Then the status is 200
    And the header "content-type" is "video/mp4"
    And the header "content-disposition" contains "attachment"
    And the header "x-content-type-options" is "nosniff"

  Scenario: A file named as a video whose bytes are not one is a link
    When I upload to "/rooms/1/messages" the file "clip.mp4" of the type "video/mp4" with the bytes "3c68746d6c3e"
    Then the status is 302
    And the query "select content_type from active_storage_blobs" gives the text "application/octet-stream"
    When I get "/rooms/1"
    Then the body contains "<a href=\"/rooms/1/messages/1/attachment\" download>clip.mp4</a>"
    And the body does not contain "<video"

  Scenario: The download link of an image sends it as a download
    Given I upload to "/rooms/1/messages" a PNG image named "pixel.png" of the type "image/png"
    When I get "/rooms/1/messages/1/attachment?disposition=attachment"
    Then the status is 200
    And the header "content-type" is "image/png"
    And the header "content-disposition" contains "attachment"

  Scenario: The size that Rails stored shows the preview, and metadata that is not JSON shows the link
    Given I upload to "/rooms/1/messages" a PNG image named "pixel.png" of the type "image/png"
    And I run the sql "update active_storage_blobs set metadata = '{\"identified\":true,\"width\":400,\"height\":200,\"analyzed\":true}'"
    When I get "/rooms/1"
    Then the body contains "width=\"200\" height=\"100\""
    Given I run the sql "update active_storage_blobs set metadata = 'not json'"
    And the app restarts
    And I sign in as "ana@example.com"
    When I get "/rooms/1"
    Then the status is 200
    And the body contains "<a href=\"/rooms/1/messages/1/attachment\" download>pixel.png</a>"

  Scenario: Sizes that Rails stored, or that were changed by hand, past any cap still show the room
    Given I upload to "/rooms/1/messages" a PNG image named "pixel.png" of the type "image/png"
    And I run the sql "update active_storage_blobs set metadata = '{\"width\":3221225472,\"height\":3221225472}'"
    When I get "/rooms/1"
    Then the status is 200
    And the body contains "<a href=\"/rooms/1/messages/1/attachment\" download>pixel.png</a>"
    When I get "/searches?q=pixel"
    Then the status is 200

  Scenario: The composer has a file picker, and posts a multipart form
    When I get "/rooms/1"
    Then the body contains "<form method=\"post\" action=\"/rooms/1/messages\" enctype=\"multipart/form-data\">"
    And the body contains "<input name=\"message[attachment]\" type=\"file\">"

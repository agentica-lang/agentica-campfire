Feature: The largest attachment
  `CAMPFIRE_MAX_ATTACHMENT_MB` (100 by default) is the largest file that a message may carry. A bigger file is refused
  with a 413 while it arrives, before the handler runs, and nothing of it is kept. The cap here is 1 MB.

  Background:
    Given a fresh database
    And the app starts with attachments of at most 1 MB
    And the first admin exists

  Scenario: A file over the size cap is refused and nothing is kept
    When I upload to "/rooms/1/messages" a file of 1048577 bytes
    Then the status is 413
    And the query "select count(*) from messages" gives 0
    And the storage folder holds 0 files
    When I upload to "/rooms/1/messages" a file of 1048576 bytes
    Then the status is 302
    And the query "select count(*) from active_storage_blobs where byte_size = 1048576" gives 1

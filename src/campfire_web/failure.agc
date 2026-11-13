## What the app answers to a failure that no handler answered itself. A failure is a 500 with no detail, except one that
## means the server is busy rather than broken (no free database connection within `CAMPFIRE_DB_CHECKOUT_MS`, a queue
## of callers that is full, a pool that is closing, a statement over its `timeout_ms`, a database that stayed locked):
## that is a 503 with `Retry-After`, as the sign-in slots answer.

import Bond from "pkg/bond/bond"
import Database from "../campfire/repo/database"

BUSY = "The server is busy, try again in a moment"
RETRY_AFTER_SECONDS = "1"

## The answer to `conn` for a failure with this message (Bond has written it to stderr already; it is never sent).
def answer(conn: Bond.Conn, message: String) -> Bond.Conn
  return Bond.header(Bond.text(conn, 503, BUSY), "retry-after", RETRY_AFTER_SECONDS) if Database.busy?(message)

  Bond.text(conn, 500, INTERNAL)
end

private

INTERNAL = "Internal Server Error"

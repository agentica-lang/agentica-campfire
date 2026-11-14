## The file of a message, `GET /rooms/ID/messages/MESSAGE/attachment`. Rails links a blob with a signed URL that anybody
## who has it can open; here the link is the room's own, so the person must be in the room, as for every page of it:
## a room that is not theirs, a message that is not in it, a message with no file and a file that is gone are the same
## 404. The file is sent as Active Storage would serve it: an image whose bytes are of its type is shown (`inline`),
## anything else is a download (`Content-Disposition: attachment` with its name), a type that a browser could run is
## sent as `application/octet-stream`, and every answer has `nosniff` and a policy that runs nothing. Ranges and
## validators are `Bond.send_file`'s. Nothing is kept by a shared cache, and the browser asks again each time, so a
## person taken out of the room stops getting the file.

import Bond from "pkg/bond/bond"
import Db from "pkg/db/db"
import Attachments from "../campfire/attachments"
import AuthWeb from "auth"
import Blobs from "../campfire/blobs"
import Database from "../campfire/repo/database"
import Rooms from "../campfire/rooms"
import Routes from "routes"

## Adds the route of the files to `app`; `storage_dir` is the folder of the files of Active Storage.
def add(app: Bond.App, pool: Database.Pool, storage_dir: String) -> Bond.App
  app |> Bond.get(Routes.ROOM_MESSAGE_ATTACHMENT) do |conn| show(conn, pool, storage_dir) end
end

private

CACHE_CONTROL = "private, no-cache"
# No script, no style, no plugin, and a sandbox, for a file that a browser opens as a page whatever it was sent as.
CONTENT_SECURITY_POLICY = "default-src 'none'; sandbox"

def show(conn: Bond.Conn, pool: Database.Pool, storage_dir: String) -> Result[Bond.Conn]
  room_id = number(conn, "id")
  message_id = number(conn, "message_id")
  found = try Database.with_connection(pool) do |db| blob_for(conn, db, room_id, message_id) end
  case found
    none -> ok(missing(conn))
    some(blob) -> sent(conn, storage_dir, blob)
  end
end

def blob_for(
  conn: Bond.Conn,
  db: Db.Connection,
  room_id: Optional[Int],
  message_id: Optional[Int],
) -> Result[Optional[Attachments.Blob]]
  user = try AuthWeb.assigned_user(conn)
  return ok(none) if user.none? or room_id.none? or message_id.none?

  in_room = try Rooms.find(db, user.unwrap!.id, room_id.unwrap!)
  return ok(none) if in_room.none?

  Attachments.find(db, room_id.unwrap!, message_id.unwrap!)
end

# The file is read after the connection is back in the pool: a download can take long.
def sent(conn: Bond.Conn, storage_dir: String, blob: Attachments.Blob) -> Result[Bond.Conn]
  path = Blobs.path(storage_dir, blob.key)
  return ok(missing(conn)) if path.none?

  head = first_bytes(path.unwrap!)
  return ok(missing(conn)) if not head.ok?

  inline = Attachments.inline?(blob.content_type, head.unwrap!)
  disposition: Optional[String] = some(blob.filename)
  content_type = Attachments.served_type(blob.content_type)
  if inline
    disposition = none
    content_type = blob.content_type
  end

  headed = Bond.header(
    Bond.header(Bond.header(conn, "cache-control", CACHE_CONTROL), "content-security-policy", CONTENT_SECURITY_POLICY),
    "cross-origin-resource-policy",
    "same-origin",
  )

  file = Bond.send_file(headed, path.unwrap!, disposition)
  return ok(missing(conn)) if not file.ok?

  ok(Bond.header(file.unwrap!, "content-type", content_type))
end

def first_bytes(path: String) -> Result[Bytes]
  File.open(path) do |handle| File.read_bytes(handle, Attachments.HEAD_BYTES) end
end

def number(conn: Bond.Conn, name: String) -> Optional[Int]
  parsed = Bond.param(conn, name).unwrap_or("").to_i
  return none if not parsed.ok?

  some(parsed.unwrap!)
end

def missing(conn: Bond.Conn) -> Bond.Conn = Bond.text(conn, 404, Routes.MISSING)

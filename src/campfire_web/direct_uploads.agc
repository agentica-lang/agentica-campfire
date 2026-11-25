## Direct uploads to the S3 service (`CAMPFIRE_STORAGE_SERVICE=s3`), in the shape of Active Storage's
## `DirectUploadsController`: `POST /rails/active_storage/direct_uploads` with `{"blob": {"filename", "content_type",
## "byte_size"}}` makes the blob row and answers the URLs that the browser puts the file at (one `PUT`, or the `parts` of
## a multipart upload), and the form of the message then names the blob by its key (`message[direct_upload]`) instead of
## carrying the file. The file never passes through the server. The URLs sign the length of each request, so the
## browser cannot send more than it said, and `claim` checks the object when the message is posted: the blob must be the
## person's own, not attached yet, as big as it was said to be, and its type is the one that its bytes say.

import Bond from "pkg/bond/bond"
import Attachments from "../campfire/attachments"
import AuthWeb from "auth"
import Blobs from "../campfire/blobs"
import Database from "../campfire/repo/database"
import ImageSize from "../campfire/image_size"
import ObjectStore from "../campfire/object_store"
import Routes from "routes"

## The field of the form of a message that names a direct upload by its key.
FIELD = "message[direct_upload]"

## The most that a name may have; the browser sends what the file was called.
MAX_FILENAME_LENGTH = 255

## The `blob` that the browser asks for.
struct Wanted
  filename: String
  content_type: String = ""
  byte_size: Int
end

## The body of the request, as Active Storage's `direct_uploads.js` sends it (it adds a `checksum`, which is ignored).
struct Asked
  blob: Wanted
end

## What the browser needs: the key of the blob (which the form of the message sends back) and where to put the file.
struct Created
  key: String
  url: String
  part_bytes: Int
  parts: List[ObjectStore.PartUrl]
end

## Adds the route to `app`. `max_bytes` is the largest file (`CAMPFIRE_MAX_ATTACHMENT_MB`). With the Disk service the
## route answers 404, so a browser that asks learns to post the file in the form.
def add(app: Bond.App, pool: Database.Pool, storage: Blobs.Storage, max_bytes: Int) -> Bond.App
  app |> Bond.post(Routes.DIRECT_UPLOADS) do |conn| create(conn, pool, storage, max_bytes) end
end

## The blob that the form of a message names, ready to attach, `none` when it does not name one. An `error` when it names
## a blob that is not the person's, is attached already, or whose object is not there as the person said it would be: a
## multipart upload that has all its parts is completed here.
def claim(conn: Bond.Conn, pool: Database.Pool, storage: Blobs.Storage) -> Result[Optional[Attachments.Blob]]
  keys = try Bond.form_all(conn, FIELD)
  return ok(none) if keys.empty? or keys[0] == ""

  return error("a direct upload was named, and the storage is the Disk service") if storage.objects.none?

  store = storage.objects.unwrap!
  key = keys[0]
  found = try Database.with_connection(pool) do |db|
    case try AuthWeb.person_in(conn, db)
      AuthWeb.Found.Person(person) -> Attachments.pending(db, person.id, key)
      AuthWeb.Found.Entry(_) -> ok(none)
    end
  end

  return error("the direct upload #{key} is not there, or is not this person's") if found.none?

  upload = found.unwrap!
  try complete(store, key, upload)
  head = try ObjectStore.first_bytes(store, key, ImageSize.HEAD_BYTES)
  content_type = Attachments.identify(head, upload.filename)
  ok(
    some(
      Attachments.Blob(
        key: key,
        filename: upload.filename,
        content_type: content_type,
        byte_size: upload.byte_size,
        size: Attachments.measure(content_type, head),
        service: ObjectStore.SERVICE_NAME,
        direct: true,
      ),
    ),
  )
end

private

# The upload has all its parts joined, and the object is as big as the person said. A completed upload is not completed
# twice: a post that failed after the completion is tried again with the object there.
def complete(store: ObjectStore.Store, key: String, upload: Attachments.Upload) -> Result[Void]
  if upload.upload_id != ""
    finished = ObjectStore.finish(store, key, upload.upload_id, upload.byte_size)
    there = ObjectStore.size_of(store, key)
    if not finished.ok? and not (there.ok? and there.unwrap! == upload.byte_size)
      return error("the upload of #{key} cannot be completed: #{finished.message}")
    end
  end

  size = try ObjectStore.size_of(store, key)
  return error("the upload of #{key} has #{size} bytes, not #{upload.byte_size}") if size != upload.byte_size

  ok()
end

def after_last(text: String, separator: String) -> String
  pieces = text.split(separator)
  return "" if pieces.empty?

  pieces[pieces.length - 1]
end

def create(conn: Bond.Conn, pool: Database.Pool, storage: Blobs.Storage, max_bytes: Int) -> Result[Bond.Conn]
  return ok(Bond.text(conn, 404, Routes.MISSING)) if storage.objects.none?

  asked = (try Bond.json_body(conn, Asked.codec)).blob
  filename = clean_name(asked.filename)
  return ok(refused(conn, "the file has no name")) if filename == ""

  if asked.byte_size < 1 or asked.byte_size > max_bytes
    return ok(refused(conn, "the file must have from 1 byte to #{max_bytes} bytes"))
  end

  store = storage.objects.unwrap!
  key = Blobs.new_key()
  plan = try ObjectStore.plan(store, key, asked.byte_size)
  content_type = asked.content_type
  if content_type == ""
    content_type = "application/octet-stream"
  end

  started = Database.with_connection(pool) do |db|
    case try AuthWeb.person_in(conn, db)
      AuthWeb.Found.Person(person) ->
        Attachments.start_upload(db, person.id, key, filename, content_type, asked.byte_size, plan.upload_id)

      AuthWeb.Found.Entry(_) -> error("a direct upload was asked for by nobody")
    end
  end

  if not started.ok?
    ObjectStore.remove(store, key, plan.upload_id)
    return error(started.message)
  end

  ok(
    Bond.header(
      Bond.json(
        conn,
        200,
        JSON.from(Created(key: key, url: plan.url, part_bytes: plan.part_bytes, parts: plan.parts)),
      ),
      "cache-control",
      "no-store",
    ),
  )
end

def refused(conn: Bond.Conn, message: String) -> Bond.Conn = Bond.json(conn, 422, JSON.from({"error": message}))

# The name of the file without the folders that a browser may put in front of it, and without control characters.
def clean_name(name: String) -> String
  last = after_last(after_last(name, "/"), "\\")
  kept = last.split("").select { |ch| ch.bytes.to_a.all? { |byte| byte >= 32 and byte != 127 } }.join("")
  named = kept.strip
  return named if named.length <= MAX_FILENAME_LENGTH

  named.slice(0, MAX_FILENAME_LENGTH)
end

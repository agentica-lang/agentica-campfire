## The file of a message (`has_one_attached :attachment` of Rails' `Message::Attachment`): a blob of Active Storage
## attached to the message under the name `attachment`. The type that is stored is found from the first bytes of the
## file and its name (`identify`), never taken from what the client said, and the download sends a file inline only
## when it is an image whose bytes say so (`inline?`); everything else is a download. `Rooms` reads the attachment of
## a message in the same query as the message (`COLUMN`), so this module imports nothing of `Rooms`.

import MIME from "std/mime"
import Regex from "std/regex"
import Db from "pkg/db/db"
import Blobs from "blobs"
import Rails from "repo/rails"
import {int_of, text_of} from "repo/rows"

## How many bytes of the start of a file `identify` and `inline?` read.
HEAD_BYTES = 16

## The column of a message query (one that has `messages` in its `from`) that holds its attachment as a JSON object for
## `parse`, "" for a message with none. A record of Rails could have more than one row (a replaced file waits for its
## purge); the newest is the one shown.
COLUMN = (
  "coalesce((select json_object('filename', blobs.filename, 'content_type', coalesce(blobs.content_type, ''), " +
  "'byte_size', blobs.byte_size) from active_storage_attachments files " +
  "join active_storage_blobs blobs on blobs.id = files.blob_id " +
  "where files.record_type = '#{Rails.MESSAGE_RECORD}' and files.record_id = messages.id " +
  "and files.name = '#{Rails.ATTACHMENT_NAME}' order by files.id desc limit 1), '') as attachment"
)

## The file of a message as a page shows it: its name, its type and its size in bytes.
struct Attachment
  filename: String
  content_type: String
  byte_size: Int
end

## A file that is stored and is to be attached to a new message: its key under the storage folder (`Blobs.store`),
## its name, its type (`identify`) and its size.
struct Blob
  key: String
  filename: String
  content_type: String
  byte_size: Int
end

## The attachment that the column `COLUMN` holds, `none` for none.
def parse(text: String) -> Optional[Attachment]
  return none if text.empty?

  # SQLite wrote this text with its JSON functions, so it decodes; a column that is not that shows no attachment.
  found = JSON.decode(text, Attachment)
  return none if not found.ok?

  some(found.unwrap!)
end

## The type of a file from its first bytes (`HEAD_BYTES`) and its name: the type of a known signature (PNG, JPEG, GIF,
## WebP, PDF) when the bytes have one, else the type of the extension. An extension that names one of those types on
## bytes that are not of it is `application/octet-stream`, so a page in a file called `x.png` is never called an image.
def identify(head: Bytes, filename: String) -> String
  sniffed = signature(head)
  return sniffed if not sniffed.empty?

  by_name = MIME.mime_type(filename)
  return OCTET_STREAM if SIGNED_TYPES.include?(by_name)

  by_name
end

## Whether a file of the stored type `content_type`, whose first bytes are `head`, may be shown in the browser: an image
## of a type with a signature (not SVG, which can hold a script) whose bytes have that signature. A row that Rails
## wrote, or one changed by hand, is checked against the bytes again.
def inline?(content_type: String, head: Bytes) -> Bool
  INLINE_TYPES.include?(content_type) and signature(head) == content_type
end

## The `Content-Type` of a download of the stored type: the type as it is, unless it is one that a browser could run
## (HTML, SVG, XML, scripts: `content_types_to_serve_as_binary` of Active Storage) or is not a plain `type/subtype`
## (it could carry a header), which are `application/octet-stream`.
def served_type(content_type: String) -> String
  return OCTET_STREAM if not Regex.match?(content_type, PLAIN_TYPE)

  return OCTET_STREAM if BINARY_TYPES.include?(content_type) or content_type.end_with?("+xml")

  content_type
end

## The stored file of the message, `none` when the message is not in the room or has no file. The caller has checked
## that the person is in the room.
def find(conn: Db.Connection, room_id: Int, message_id: Int) -> Result[Optional[Blob]]
  rows = try Db.query(
    conn,
    "select blobs.key, blobs.filename, coalesce(blobs.content_type, '') as content_type, blobs.byte_size " +
    "from messages join active_storage_attachments files on files.record_type = '#{Rails.MESSAGE_RECORD}' " +
    "and files.record_id = messages.id and files.name = '#{Rails.ATTACHMENT_NAME}' " +
    "join active_storage_blobs blobs on blobs.id = files.blob_id " +
    "where messages.id = ? and messages.room_id = ? order by files.id desc limit 1",
    [Db.Value.Int(message_id), Db.Value.Int(room_id)],
  )

  return ok(none) if rows.empty?

  row = rows[0]
  ok(
    some(
      Blob(
        key: text_of(row, "key"),
        filename: text_of(row, "filename"),
        content_type: text_of(row, "content_type"),
        byte_size: int_of(row, "byte_size"),
      ),
    ),
  )
end

## Writes the blob and attaches it to the message, in the transaction `tx` that writes the message, as Active Storage
## does for the local Disk service. The checksum is left out (the column takes none): it would mean reading the whole
## file again while nothing reads it back.
def attach_in(tx: Db.Connection, message_id: Int, blob: Blob) -> Result[Void]
  rows = try Db.query(
    tx,
    "insert into active_storage_blobs (key, filename, content_type, metadata, service_name, byte_size, created_at) " +
    "values (?, ?, ?, '#{METADATA}', '#{SERVICE_NAME}', ?, #{Rails.NOW}) returning id",
    [
      Db.Value.Text(blob.key),
      Db.Value.Text(blob.filename),
      Db.Value.Text(blob.content_type),
      Db.Value.Int(blob.byte_size),
    ],
  )

  try Db.execute(
    tx,
    "insert into active_storage_attachments (name, record_type, record_id, blob_id, created_at) " +
    "values ('#{Rails.ATTACHMENT_NAME}', '#{Rails.MESSAGE_RECORD}', ?, ?, #{Rails.NOW})",
    [Db.Value.Int(message_id), rows[0].get("id", Db.Value.Null)],
  )

  ok()
end

## Takes the file off the message, in the transaction `tx` that deletes it, and gives the keys of the blobs deleted, for
## the caller to delete their files once it has committed.
def detach_in(tx: Db.Connection, message_id: Int) -> Result[List[String]]
  Blobs.detach(tx, Rails.MESSAGE_RECORD, message_id, Rails.ATTACHMENT_NAME)
end

private

OCTET_STREAM = "application/octet-stream"
# What `ActiveStorage::Blob#analyze` would find first; the app does not analyze (#61 does the previews).
METADATA = "{\"identified\":true}"
# The service of `config/storage.yml` of Rails Campfire in production (`local`, the Disk service).
SERVICE_NAME = "local"
PNG = "image/png"
JPEG = "image/jpeg"
GIF = "image/gif"
WEBP = Rails.WEBP
PDF = "application/pdf"
# The types that `signature` knows, and of those the images that may be shown inline.
SIGNED_TYPES = [PNG, JPEG, GIF, WEBP, PDF]
INLINE_TYPES = [PNG, JPEG, GIF, WEBP]
# `ActiveStorage.content_types_to_serve_as_binary`, and the scripts that `std/mime` names otherwise.
BINARY_TYPES = [
  "text/html", "text/javascript", "application/javascript", "image/svg+xml", "application/postscript",
  "application/x-shockwave-flash", "text/xml", "application/xml", "application/xhtml+xml", "application/mathml+xml",
  "text/cache-manifest",
]
PLAIN_TYPE = /\A[a-z0-9][a-z0-9.+-]*\/[a-z0-9][a-z0-9.+-]*\z/

# The type of the signature that the bytes start with, "" for none.
def signature(head: Bytes) -> String
  hex = OpenSSL.Digest.hexencode(head.take(HEAD_BYTES))
  return PNG if hex.start_with?("89504e470d0a1a0a")

  return JPEG if hex.start_with?("ffd8ff")

  return GIF if hex.start_with?("474946383761") or hex.start_with?("474946383961")

  # `RIFF`, four bytes of size, then `WEBP`.
  return WEBP if hex.start_with?("52494646") and hex.slice(16, 8) == "57454250"

  return PDF if hex.start_with?("255044462d")

  ""
end

## The blobs of Active Storage as its Disk service keeps them: a row of `active_storage_blobs` and a file under the
## storage folder at `xx/yy/KEY`. The avatars and the attachments of messages share them.

import Regex from "std/regex"
import Db from "pkg/db/db"
import DataDir from "data_dir"
import Rails from "repo/rails"
import {int_of, text_of} from "repo/rows"

## The file of a blob under `storage_dir`, where the Disk service of Rails puts it: `xx/yy/KEY`, the first two and the
## next two characters of the key as folders. `none` for a key that is not one of Active Storage's.
def path(storage_dir: String, key: String) -> Optional[String]
  return none if not Regex.match?(key, KEY)

  joined = Path.join([storage_dir, key.slice(0, 2), key.slice(2, 2), key])
  return none if not joined.ok?

  some(joined.unwrap!)
end

## A new key as Active Storage makes one (`has_secure_token`, 28 characters of base 36). A byte from 252 on is skipped,
## so each character is as likely.
def new_key() -> String
  key = ""
  while key.length < KEY_LENGTH
    for byte in OpenSSL.Random.random_bytes(KEY_LENGTH)
      if byte < FAIR_BELOW and key.length < KEY_LENGTH
        key = "#{key}#{ALPHABET.slice(byte % ALPHABET.length, 1)}"
      end
    end
  end

  key
end

## Moves the file at `from` to the place of `key` under `storage_dir`, making its two folders (private) when they are
## missing. Both are on one file system: the uploads are received under the storage folder.
def store(storage_dir: String, from: String, key: String) -> Result[Void]
  to = path(storage_dir, key)
  return error("not a key of Active Storage: #{key}") if to.none?

  try DataDir.ensure(try Path.join([storage_dir, key.slice(0, 2), key.slice(2, 2)]))
  Path.rename(from, to.unwrap!)
end

## Deletes the files of `keys`, after the transaction that deleted their rows has committed (a file is not undone by a
## rollback). A file that cannot be deleted is logged and left: its row is gone, so nothing links it.
def remove_files(storage_dir: String, keys: List[String]) -> Void
  for key in keys
    case path(storage_dir, key)
      some(file) ->
        gone = Path.remove(file)
        if not gone.ok?
          IO.warn("campfire: cannot delete the stored file #{key}: #{gone.message}")
        end

      none -> nil
    end
  end
end

## Deletes the files under `storage_dir` that no blob row names: what a crash between `store` and the commit of the
## message left. Only the start calls it, when no request is storing a file yet.
def sweep(db: Db.Connection, storage_dir: String) -> Result[Void]
  for first in try Dir.list(storage_dir)
    next if not Regex.match?(first, FOLDER)

    for second in try Dir.list(try Path.join([storage_dir, first]))
      next if not Regex.match?(second, FOLDER)

      folder = try Path.join([storage_dir, first, second])
      for key in try Dir.list(folder)
        next if try named?(db, key)

        gone = Path.remove(try Path.join([folder, key]))
        if not gone.ok?
          IO.warn("campfire: cannot delete the orphan file #{key}: #{gone.message}")
        end
      end
    end
  end

  ok()
end

## The blob and its variants, when nothing is attached to it any more: the variants go first, since their rows and
## the attachments of their images hold keys to it. It gives the keys of every blob deleted, in the transaction `tx`.
def drop(tx: Db.Connection, blob_id: Int) -> Result[List[String]]
  return ok([]) if not try unused?(tx, blob_id)

  keys: List[String] = []
  variants = try Db.query(
    tx,
    "select id from active_storage_variant_records where blob_id = ?",
    [Db.Value.Int(blob_id)],
  )

  for variant in variants
    keys = keys.concat(try drop_variant(tx, int_of(variant, "id")))
  end

  found = try Db.query(tx, "select key from active_storage_blobs where id = ?", [Db.Value.Int(blob_id)])
  try Db.execute(tx, "delete from active_storage_blobs where id = ?", [Db.Value.Int(blob_id)])
  ok(keys.concat(found.map do |row| text_of(row, "key") end))
end

## Deletes the attachments named `name` of the record and the blobs that are left with none, in `tx`. It gives the keys
## of the blobs deleted.
def detach(tx: Db.Connection, record_type: String, record_id: Int, name: String) -> Result[List[String]]
  attached = try Db.query(
    tx,
    "select id, blob_id from active_storage_attachments where record_type = ? and record_id = ? and name = ?",
    [Db.Value.Text(record_type), Db.Value.Int(record_id), Db.Value.Text(name)],
  )

  keys: List[String] = []
  for row in attached
    try Db.execute(tx, "delete from active_storage_attachments where id = ?", [Db.Value.Int(int_of(row, "id"))])
    keys = keys.concat(try drop(tx, int_of(row, "blob_id")))
  end

  ok(keys)
end

private

# Active Storage keys are 28 characters of base 36 (`OpenSSL.Random.base36`). Only those can be a name in the folder of
# the files: whatever else a row holds is never turned into a path.
KEY = /\A[0-9a-z]{4,64}\z/
FOLDER = /\A[0-9a-z]{2}\z/
KEY_LENGTH = 28
ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"
FAIR_BELOW = 252

# A variant record, its image (an attachment of a blob) and that blob.
def drop_variant(tx: Db.Connection, variant_id: Int) -> Result[List[String]]
  keys = try detach(tx, Rails.VARIANT_RECORD, variant_id, Rails.VARIANT_IMAGE_NAME)
  try Db.execute(tx, "delete from active_storage_variant_records where id = ?", [Db.Value.Int(variant_id)])
  ok(keys)
end

def unused?(tx: Db.Connection, blob_id: Int) -> Result[Bool]
  rows = try Db.query(
    tx,
    "select 1 from active_storage_attachments where blob_id = ? limit 1",
    [Db.Value.Int(blob_id)],
  )

  ok(rows.empty?)
end

def named?(db: Db.Connection, key: String) -> Result[Bool]
  rows = try Db.query(db, "select 1 from active_storage_blobs where key = ? limit 1", [Db.Value.Text(key)])
  ok(not rows.empty?)
end

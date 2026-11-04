## What `Users::AvatarsController` of Rails Campfire needs for the avatar of a user, over the tables of Active Storage
## and the files that its Disk service wrote. The app never makes an avatar or its variant (that is image processing,
## which Rails does with libvips): it finds the WebP that Rails made for the variant `:square`, and where it lies.

import Regex from "std/regex"
import Db from "pkg/db/db"
import Rails from "repo/rails"
import {text_of} from "repo/rows"

# The colours of the circle behind the initials, in the order of `AVATAR_COLORS` of `Users::AvatarsHelper`.
COLORS = [
  "#AF2E1B", "#CC6324", "#3B4B59", "#BFA07A", "#ED8008", "#ED3F1C", "#BF1B1B", "#736B1E", "#D07B53", "#736356",
  "#AD1D1D", "#BF7C2A", "#C09C6F", "#698F9C", "#7C956B", "#5D618F", "#3B3633", "#67695E",
]

# `\b\w` of `User#initials`: the first letter of each word.
INITIALS = /\b\w/

# Active Storage keys are 28 characters of base 36 (`SecureRandom.base36`). Only those can be a name in the folder of
# the files: whatever else a row holds (it came from a database, not from a visitor) is never turned into a path.
KEY = /\A[0-9a-z]{4,64}\z/

# The shape of the type of an original that is sent as it is: `image/...` from a database, with nothing that
# could carry a line break into a header (`sendable?` also leaves out SVG).
SENDABLE_TYPE = /\Aimage\/(?:[a-z0-9.+-]+)\z/

## A user as the avatar link needs them: the name for the initials, and the file to send, `none` for a person with no
## avatar. `file_key` is the key of the blob to send and `content_type` its type: the WebP that Rails made for the
## avatar, or, when Rails has not processed one yet (it does so on the first request), the original image.
export struct Avatar
  name: String
  file_key: Optional[String]
  content_type: String
end

## The avatar of the user, `none` when there is no such user. A user that is deactivated or banned still has theirs,
## as in Rails. The file is the image of the `ActiveStorage::VariantRecord` of the avatar's blob that is a WebP (the
## only variant that the app of Rails defines is `:square`, so there is one, and the digest that names the variation,
## a hash of a Ruby `Marshal` dump, is not something to compute). Without one, it is the avatar's own blob, since the
## app makes no variant and a person who has a picture should not lose it: only a type that is a plain `image/...`
## and not SVG (which can hold a script) is sent, anything else counts as no avatar.
export def find(conn: Db.Connection, user_id: Int) -> Result[Optional[Avatar]]
  users = try Db.query(conn, "select name from users where id = ?", [Db.Value.Int(user_id)])
  if users.empty?
    return ok(none)
  end

  name = text_of(users[0], "name")
  variants = try Db.query(
    conn,
    "select variant_blobs.key as key from active_storage_attachments avatars " +
    "join active_storage_variant_records variants on variants.blob_id = avatars.blob_id " +
    "join active_storage_attachments images on images.record_type = '#{Rails.VARIANT_RECORD}' " +
    "and images.record_id = variants.id and images.name = '#{Rails.VARIANT_IMAGE_NAME}' " +
    "join active_storage_blobs variant_blobs on variant_blobs.id = images.blob_id " +
    "where avatars.record_type = '#{Rails.USER_RECORD}' and avatars.record_id = ? " +
    "and avatars.name = '#{Rails.AVATAR_NAME}' " +
    "and variant_blobs.content_type = '#{Rails.WEBP}' order by variants.id desc limit 1",
    [Db.Value.Int(user_id)],
  )

  if not variants.empty?
    return ok(some(Avatar(name: name, file_key: some(text_of(variants[0], "key")), content_type: Rails.WEBP)))
  end

  originals = try Db.query(
    conn,
    "select blobs.key as key, blobs.content_type as content_type from active_storage_attachments avatars " +
    "join active_storage_blobs blobs on blobs.id = avatars.blob_id " +
    "where avatars.record_type = '#{Rails.USER_RECORD}' and avatars.record_id = ? " +
    "and avatars.name = '#{Rails.AVATAR_NAME}' order by avatars.id desc limit 1",
    [Db.Value.Int(user_id)],
  )

  if originals.empty? or not sendable?(text_of(originals[0], "content_type"))
    return ok(some(Avatar(name: name, file_key: none, content_type: "")))
  end

  original = originals[0]
  return ok(
    some(
      Avatar(name: name, file_key: some(text_of(original, "key")), content_type: text_of(original, "content_type")),
    ),
  )
end

## The file of a blob under `storage_dir`, where the Disk service of Rails puts it: `xx/yy/KEY`, the first two and the
## next two characters of the key as folders. `none` for a key that is not one of Active Storage's.
export def path(storage_dir: String, key: String) -> Optional[String]
  if not Regex.match?(key, KEY)
    return none
  end

  joined = Path.join([storage_dir, key.slice(0, 2), key.slice(2, 2), key])
  if not joined.ok?
    return none
  end

  return some(joined.unwrap!)
end

## The letters in the circle: the first letter of each word of the name (`Bea Smith` is `BS`).
export def initials(name: String) -> String
  return Regex.find_all(name, INITIALS).map do |found| found.text end.join("")
end

## The colour behind the initials of the user, from the CRC-32 of their id, as `avatar_background_color` of Rails does.
export def color(user_id: Int) -> String
  checksum = Zlib.crc32("#{user_id}".bytes).unwrap!
  return COLORS[checksum % COLORS.size]
end

# A plain image type, and not SVG: RE2 has no lookahead, so the SVG types are left out here.
def sendable?(content_type: String) -> Bool
  return Regex.match?(content_type, SENDABLE_TYPE) and not content_type.start_with?("image/svg")
end

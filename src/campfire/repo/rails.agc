## What the database shares with a Rails Campfire (basecamp/once-campfire, pinned at 90b3300): the integer values of
## its enums and the form of its timestamps. The schema is the Rails one, so a database that Rails made opens as it is
## (see `database.agc`), and every module that runs SQL on `users` and its neighbours names these values here.

## `users.role`, as `enum :role, %i[ member administrator bot ]` of Rails writes it.
MEMBER = 0
ADMINISTRATOR = 1
BOT = 2
## `users.status`, as `enum :status, %i[ active deactivated banned ]` of Rails writes it. Only the active may sign in
## and be put in a room; a deactivated person is one that an administrator may bring back.
ACTIVE = 0
DEACTIVATED = 1
BANNED = 2
## `rooms.type`, the class name of the single-table inheritance of Rails (`Rooms::Open`, `Rooms::Closed`,
## `Rooms::Direct`): an open room has every active person in it, a closed room the people chosen for it, and a direct
## room has no name and is between the people in it.
ROOM_OPEN = "Rooms::Open"
ROOM_CLOSED = "Rooms::Closed"
ROOM_DIRECT = "Rooms::Direct"
## `memberships.involvement` of a room that the person has hidden from their sidebar (`enum :involvement, %i[ invisible
## nothing mentions everything ]` of Rails writes the names, as text).
INVISIBLE = "invisible"
## The other levels of `memberships.involvement`: `nothing` (no notification, the room is in the sidebar), `mentions`
## (the default) and `everything`. Only the default is written, to show a hidden room again, and the other two are
## only read back from a Rails database: notifications do not exist yet, and the issues of push (#81) and mentions
## (#57) bring the levels back to the page of the room.
NOTHING = "nothing"
MENTIONS = "mentions"
EVERYTHING = "everything"
## The `record_type` and `name` of the row of `action_text_rich_texts` that holds the body of a message.
MESSAGE_RECORD = "Message"
BODY_NAME = "body"
## What Active Storage writes for the avatar of a user (`has_one_attached :avatar`): an attachment named `avatar` of the
## `User`, and, once Rails has made the variant `:square` (a WebP of at most 512 pixels), a row of
## `active_storage_variant_records` for the blob of the original, whose own image is another attachment, named `image`,
## of that `ActiveStorage::VariantRecord`.
USER_RECORD = "User"
AVATAR_NAME = "avatar"
VARIANT_RECORD = "ActiveStorage::VariantRecord"
VARIANT_IMAGE_NAME = "image"
WEBP = "image/webp"
## Rails keeps a `datetime` in SQLite as UTC text with six decimals, `2026-03-01 09:00:00.123456`. SQLite's `%f` has
## three, so the last three are zeros: the text is the same length as Rails' own, which is what makes it sort, and
## compare, like time against the rows that Rails wrote.
STAMP = "%Y-%m-%d %H:%M:%f000"
## The SQL for the time now, in the form above (`STAMP` is the format, for a time moved by a modifier:
## `strftime('#{Rails.STAMP}', 'now', '-30 days')`). Rails' columns have no default, so every insert sets
## `created_at` and `updated_at` with it.
NOW = "strftime('#{STAMP}', 'now')"
## How long after `memberships.connected_at` a person counts as connected to a room (`CONNECTION_TTL` of
## `Membership::Connectable`): a message makes a room unread only for the people who are not.
CONNECTION_TTL_SECONDS = 60
## The names of the roles as the pages and `Auth.User` carry them.
MEMBER_NAME = "member"
ADMINISTRATOR_NAME = "administrator"
BOT_NAME = "bot"

## The name of a role: `member`, `administrator` or `bot`. A value that is not one of the three (a row that did not
## come from this schema) is a member, who may do the least.
def role_name(role: Int) -> String
  return ADMINISTRATOR_NAME if role == ADMINISTRATOR

  return BOT_NAME if role == BOT

  MEMBER_NAME
end

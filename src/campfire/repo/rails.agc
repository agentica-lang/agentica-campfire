## What the database shares with a Rails Campfire (basecamp/once-campfire, pinned at 90b3300): the integer values of
## its enums and the form of its timestamps. The schema is the Rails one, so a database that Rails made opens as it is
## (see `database.agc`), and every module that runs SQL on `users` and its neighbours names these values here.

## `users.role`, as `enum :role, %i[ member administrator bot ]` of Rails writes it.
export MEMBER = 0
export ADMINISTRATOR = 1
export BOT = 2

## `users.status`, as `enum :status, %i[ active deactivated banned ]` of Rails writes it. Only the active may sign in
## and be put in a room; a deactivated person is one that an administrator may bring back.
export ACTIVE = 0
export DEACTIVATED = 1
export BANNED = 2

## `rooms.type`, the class name of the single-table inheritance of Rails (`Rooms::Open`, `Rooms::Closed`,
## `Rooms::Direct`): an open room has every active person in it, a closed room the people chosen for it, and a direct
## room has no name and is between the people in it.
export ROOM_OPEN = "Rooms::Open"
export ROOM_CLOSED = "Rooms::Closed"
export ROOM_DIRECT = "Rooms::Direct"

## `memberships.involvement` of a room that the person has hidden from their sidebar (`enum :involvement, %i[ invisible
## nothing mentions everything ]` of Rails writes the names, as text).
export INVISIBLE = "invisible"

## The other levels of `memberships.involvement`: `nothing` (no notification, the room is in the sidebar), `mentions`
## (the default) and `everything`.
export NOTHING = "nothing"
export MENTIONS = "mentions"
export EVERYTHING = "everything"

## The `record_type` and `name` of the row of `action_text_rich_texts` that holds the body of a message.
export MESSAGE_RECORD = "Message"
export BODY_NAME = "body"

## What Active Storage writes for the avatar of a user (`has_one_attached :avatar`): an attachment named `avatar` of the
## `User`, and, once Rails has made the variant `:square` (a WebP of at most 512 pixels), a row of
## `active_storage_variant_records` for the blob of the original, whose own image is another attachment, named `image`,
## of that `ActiveStorage::VariantRecord`.
export USER_RECORD = "User"
export AVATAR_NAME = "avatar"
export VARIANT_RECORD = "ActiveStorage::VariantRecord"
export VARIANT_IMAGE_NAME = "image"
export WEBP = "image/webp"

## Rails keeps a `datetime` in SQLite as UTC text with six decimals, `2026-03-01 09:00:00.123456`. SQLite's `%f` has
## three, so the last three are zeros: the text is the same length as Rails' own, which is what makes it sort, and
## compare, like time against the rows that Rails wrote.
export STAMP = "%Y-%m-%d %H:%M:%f000"

## The SQL for the time now, in the form above (`STAMP` is the format, for a time moved by a modifier:
## `strftime('#{Rails.STAMP}', 'now', '-30 days')`). Rails' columns have no default, so every insert sets
## `created_at` and `updated_at` with it.
export NOW = "strftime('#{STAMP}', 'now')"

## How long after `memberships.connected_at` a person counts as connected to a room (`CONNECTION_TTL` of
## `Membership::Connectable`): a message makes a room unread only for the people who are not.
export CONNECTION_TTL_SECONDS = 60

## The names of the roles as the pages and `Auth.User` carry them.
export MEMBER_NAME = "member"
export ADMINISTRATOR_NAME = "administrator"
export BOT_NAME = "bot"

## The name of a role: `member`, `administrator` or `bot`. A value that is not one of the three (a row that did not
## come from this schema) is a member, who may do the least.
export def role_name(role: Int) -> String
  if role == ADMINISTRATOR
    return ADMINISTRATOR_NAME
  end

  if role == BOT
    return BOT_NAME
  end

  return MEMBER_NAME
end

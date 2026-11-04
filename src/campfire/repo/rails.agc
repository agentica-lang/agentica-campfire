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

## Rails keeps a `datetime` in SQLite as UTC text with six decimals, `2026-03-01 09:00:00.123456`. SQLite's `%f` has
## three, so the last three are zeros: the text is the same length as Rails' own, which is what makes it sort, and
## compare, like time against the rows that Rails wrote.
export STAMP = "%Y-%m-%d %H:%M:%f000"

## The SQL for the time now, in the form above (`STAMP` is the format, for a time moved by a modifier:
## `strftime('#{Rails.STAMP}', 'now', '-30 days')`). Rails' columns have no default, so every insert sets
## `created_at` and `updated_at` with it.
export NOW = "strftime('#{STAMP}', 'now')"

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

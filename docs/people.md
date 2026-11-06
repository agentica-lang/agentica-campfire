# The join link and the people

## Joining

The account has a join code, made by the first run (`a1b2-c3d4-e5f6`). `/join/CODE` is a form
where a new person signs up with a name, an email and a password (at least 8 characters). They
become a member, join every open room that exists and are signed in. It is the only page besides
the sign-in ones that needs no session.

- A code that is not the account's answers the `404` of a missing page, and the form is not read.
- An email that has an account is refused with a message. The address of a deactivated person is not taken: a
  deactivation renames it (see below).
- Forms that arrive together with one email make one person: the code and the email are checked
  again inside the write transaction, after the password was hashed under the same limit of two
  hashes at a time (`503` with `Retry-After` past it, with the form again).

## The people page

`People` in the sidebar (`/users`) lists the active people for everybody.

An administrator also sees their emails and roles, and the join link with a button that makes a new
one (the old link stops working at once). The link starts with `CAMPFIRE_BASE_URL` when that is set
and is only the path otherwise. An administrator can deactivate each person but themselves, and
reactivate a deactivated one.

Deactivating is what `User#deactivate` does in Rails: it ends the sessions and the password-reset links of that
person, deletes their push subscriptions and searches and their memberships of open and closed rooms (the direct ones
stay), and renames their address to `name-deactivated-UUID@host`, so the address is free again and a new person can
join with it. Their messages and rooms stay. Reactivating (which Rails does not have) gives back the original address,
which is `409` when another account has it by then, and puts the person in every open room, as a new person is; the
closed rooms they were in are lost, as in Rails. Only a marker with a UUID right before the `@` is taken away, so an
address that has `-deactivated-` by its owner's choice comes back as it was, and a person deactivated before this
rename keeps their address.

Everything but the page answers `403` to a member who is not an administrator, and `404` for a user
that does not exist or is a bot. The role is checked again inside the transaction.

## The account settings page

`Account` in the sidebar (`/account/edit`, `AccountsController#edit`) shows the name of the account and the active
people, the administrators first, to everybody who is signed in. An administrator also sees the emails and a box that
renames the account (`account[name]`, `PATCH /account`, or a `POST` with `_method=patch` from the form), and for each
person but themselves a switch that makes them an administrator or a member (`user[role]`, `PATCH /account/users/ID`)
and a button that removes them (`DELETE /account/users/ID`, or a `POST` with `_method=delete`). Removing is what Rails
does: it deactivates the person (ends their sessions and their sockets, keeps them from signing in; their messages and
rooms stay), and the people page brings them back. The effects are those of Rails' `User#deactivate`
(see above), plus the sockets. A person who is deactivated already is `404` here, as `User.active.find` is in Rails.

The checks come in the order of Rails' filters: no session redirects to sign-in, a member who is not an administrator is
`403` before anything else is read, then the person (`404` for a user that does not exist, is not active or is a bot),
then the form (`400` for a missing field). Where this differs from Rails: a name that is blank or over 100 characters is
`422` with the form again (Rails saves anything); a role that is not `member` or `administrator` is `422` (Rails takes
it for `member`); and an administrator cannot change or remove themselves on the server either (Rails only hides the
controls), so the account always keeps an administrator. Any other method on the two paths is a `405` that lists their
methods.

## The user page and the profile

`GET /users/ID` (`UsersController#show`) is open to anybody who is signed in, for a user in any status: the name, the
bio, the email address for an administrator only, and a button that opens a direct message with an active user. A bot
has only the button, and a deactivated person only their name and "is no longer on this account". A user that does not
exist (or an id that is not a number, or `me`) is `404`. Banning and the sign-in transfer link of Rails are not here
yet.

`/users/me/profile` (`Users::ProfilesController`) is the person's own form for the name, the email address, the
password and the bio (`user[name]`, `user[email_address]`, `user[password]`, `user[bio]`), saved with a `PATCH` (a real
one, a `PUT`, or a `POST` with `_method` `patch` or `put`; any other method is `405` with the `Allow` list) and a
redirect back. The page also lists the rooms the person is in, with the link to the sidebar setting of each shared
one. The picture is shown but cannot be changed yet.

A new password needs the current one (`user[password_challenge]`), checked in the hashing slot of the new hash, at
most 10 times in 3 minutes for each person (`429` with `Retry-After` past it); a wrong or missing one is `422` and
saves nothing. Saving it also ends every other session of the person and their push subscriptions, and their sockets
(they must sign in again; this browser keeps its session), as `sign_out_all_sessions` does in Rails. The other fields
need no current password.

Where this differs from Rails: `:id` is `me` or the person's own id and another user's profile is `404` (Rails ignores
the id and edits the signed-in person); a blank name, an invalid or taken address (in any case, among all accounts), a
bio over 200 characters and a password under 8 characters are `422` with the form again (Rails saves anything and
fails on the unique index); a blank email or password leaves the old one (Rails would save a blank email); the address
is stored in lower case like the join form's. The password is hashed under the same limit of two hashes at a time as
sign-in (`503` with `Retry-After` past it). A save with none of the four fields is `400`. The address of a person who
was deactivated before the rename of PR 101 is still their plain address, so it still counts as taken here and at the
join form.

## The tables

The people and the account live in the tables of a Rails Campfire, with Rails' columns and types
(`src/campfire/repo/migrations/m0001_accounts.agc` to `m0003_sessions.agc`):

- `accounts`: one row (`singleton_guard` is always 0 and unique), with `name` and `join_code`.
- `users`: `email_address` (a person; a bot has none), `password_digest`, `bot_token` (a bot), and the
  integers `role` (0 member, 1 administrator, 2 bot) and `status` (0 active, 1 deactivated, 2
  banned). Only an active person signs in or is put in a room. `src/campfire/repo/rails.agc` names
  the values.
- `sessions`: a row per sign-in, with the random `token` that the session cookie holds inside its
  signed value, `user_agent`, `ip_address` and `last_active_at`.

Every timestamp is UTC text as Rails writes it in SQLite, `2026-03-01 09:00:00.123456`; the app
writes the last three decimals as zeros. Rails' columns have no defaults, so the app sets
`created_at` and `updated_at` in every insert. The unique index on `email_address` compares bytes
and Rails stores an address as it was typed, so the app stores its own in lower case and looks an address up
with `lower(email_address)`: a row that Rails made as `David@37signals.com` signs in with any case. Of two rows
that differ only in case, the lower case one is the person. Deactivating a person renames their address
as Rails does, and reactivating restores it. The banned are not listed: the app does not ban yet.

The security notes on the code are in [security.md](security.md).

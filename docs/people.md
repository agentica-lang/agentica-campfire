# The join link and the people

## Joining

The account has a join code, made by the first run (`a1b2-c3d4-e5f6`). `/join/CODE` is a form
where a new person signs up with a name, an email and a password (at least 8 characters). They
become a member, join every open room that exists and are signed in. It is the only page besides
the sign-in ones that needs no session.

- A code that is not the account's answers the `404` of a missing page, and the form is not read.
- An email that has an account (a deactivated person's too) is refused with a message.
- Forms that arrive together with one email make one person: the code and the email are checked
  again inside the write transaction, after the password was hashed under the same limit of two
  hashes at a time (`503` with `Retry-After` past it, with the form again).

## The people page

`People` in the sidebar (`/users`) lists the active people for everybody.

An administrator also sees their emails and roles, and the join link with a button that makes a new
one (the old link stops working at once). The link starts with `CAMPFIRE_BASE_URL` when that is set
and is only the path otherwise. An administrator can deactivate each person but themselves, and
reactivate a deactivated one.

Deactivating ends the sessions of that person and keeps them from signing in; their messages and
rooms stay. Reactivating puts them in the open rooms that were made while they were away.

Everything but the page answers `403` to a member who is not an administrator, and `404` for a user
that does not exist or is a bot. The role is checked again inside the transaction.

The security notes on the code are in [security.md](security.md).

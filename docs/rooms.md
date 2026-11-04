# Rooms and messages

There are no live updates yet: a page shows what the database holds when it is asked for.

The sidebar lists the rooms that a person is in. The first run makes the open room "All Talk".

## Kinds

- **Open**: `New room` (any member may make one) puts every active person in it. A person who
  joins gets every open room that exists; a reactivated person gets the open rooms made while
  they were away.
- **Closed**: `New closed room` has a member picker (checkboxes of the active people). The maker is
  always in it, and only the chosen people get a membership, in one transaction.
- **Direct**: `New direct message` picks one or more people. The same people (the person included)
  open the direct message that exists instead of making a second one, even when forms arrive
  together. Each person sees it named after the others.

Not yet: leaving a room, restricting who may make an open room to administrators, removing
yourself.

## Settings

`/rooms/ID/settings` exists for closed rooms only. The maker and an account administrator can
rename the room and add or remove people. Another member is answered `403` and sees no Settings
link; a person who is not in the room gets `404`, checked first. For a room of another type, the
settings are the same `404`, before the form is read.

The form never takes out the person who sends it. Saving applies only its own changes, so a stale
form neither removes someone added since nor brings back someone removed since. A person who is not
active stays in. The update checks again, inside its transaction, that the room is still closed and
that the person may still change it, and rolls back otherwise.

## Messages

`/rooms/ID` shows the last 40 messages, the newest at the bottom, with an `Older messages` link to
the 40 before them (`?before=ID`). Messages are paged by `created_at` as Rails does, not by id: the
rows of a database that Rails seeded are not in the order of their time. `?before=ID` is the messages
before the time of message ID, and messages that share a time go by id.

A message is a row of `messages`, its HTML body in `action_text_rich_texts` (`record_type` `Message`,
`name` `body`) and its plain text in the FTS5 table `message_search_index` (`rowid` is the message id),
all written in one transaction. The form sends plain text of at most 10000 characters, stripped of the
space around it, which is stored as HTML (escaped, a new line as `<br>`). An HTML body, from the form
that is to come or from Rails, is cleaned by `HtmlSanitizer.sanitize` before it is stored and again
before it is shown. There is no link or mention handling yet.

The form carries a random `client_message_id`, which is stored and used for nothing else: as in Rails
there is no unique index on it, so posting it twice (a double click) stores two messages. This is a known
gap: a double click or a retry after a lost answer posts twice, until the client checks `client_message_id`
(the app does not).

Who may see a room, and why a non-member gets `404`: [security.md](security.md).

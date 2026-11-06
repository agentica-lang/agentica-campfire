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
that is to come or from Rails, is cleaned by `HtmlSanitizer.sanitize` before it is stored and when it
is read. There is no link or mention handling yet.

Each message on a page is `<div id="message_ID" data-message-id="ID">` with the author and the time, and its
body in `<div id="presentation_message_ID">` inside `<turbo-frame id="edit_message_ID">`; the list is
`<div id="messages_rooms_open_ID">` (`closed` or `direct` for the other types). `GET /rooms/ID/messages` is
the same markup without the layout or the sidebar: the 40 messages before `?before=ID` (the newest 40 without
it), `204` when there are none, `404` for a room that is not the person's. Every page links one fingerprinted
stylesheet, `/assets/campfire-DIGEST.css` (see [Assets](#assets)).

The room page and the page of older messages are kept whole in a cache (`CAMPFIRE_RESPONSE_CACHE_MB`, 64 by default, 0
for none), as Rails Campfire keeps the answer of `rooms#show` and `messages#index`. A page is kept for one person, one
room and one `?before=`, so nobody is sent a page that was made for somebody else, and only a 200 is kept. It is valid
for one version of the database: a connection of its own reads `PRAGMA data_version`, which changes whenever any
connection or program commits (a new message, an edit, a delete, a change of members, a rename of the room or of a
person), and the version is in the key, so the next request builds the page again. Every page has a weak `ETag` (a digest
of its bytes) and `Cache-Control: max-age=0, private, must-revalidate`, and a request with `If-None-Match` of that tag is
answered `304`. The `client_message_id` of the form is drawn when a page is made, so two loads at one version share it;
the app stores it and does nothing else with it. The cache of messages (`CAMPFIRE_CACHE_MB`) is separate: it saves
rendering a message again when the page is built.

The form of a message has the fields `message[body]` and `message[client_message_id]`, the names that Rails
uses. A post that sends `Accept: text/vnd.turbo-stream.html` is answered `200` with a Turbo Stream that appends
the new message to the list of the room (`<turbo-stream action="append" target="messages_rooms_open_ID">`); any
other post is redirected to the room page. A message also touches `rooms.updated_at` and sets `unread_at` of
the other members who have not made the room invisible and are not connected, as Rails does. Writers take
the write lock of SQLite one at a time (`BEGIN IMMEDIATE` and a busy timeout), and the body is sanitized before
the transaction begins so that the lock is not held for it.

The form carries a random `client_message_id`, which is stored and used for nothing else: as in Rails
there is no unique index on it, so posting it twice (a double click) stores two messages. This is a known
gap: a double click or a retry after a lost answer posts twice, until the client checks `client_message_id`
(the app does not).

Who may see a room, and why a non-member gets `404`: [security.md](security.md).

## Sidebar and search

`GET /users/me/sidebar` is the sidebar as a whole document: `<ul id="shared_rooms">` with the open and
closed rooms of the person that they have not made invisible, then their direct messages. The other
pages carry the same column.

`GET /searches?q=words` is a whole document with the messages of the rooms the person is in (any
involvement) whose text matches the words in `message_search_index`: the newest 100, oldest first, in the
markup of the room page. What is typed is words, as in Rails (`SearchesController`): everything that is not a
letter, digit or `_` separates words, and each word goes to FTS5 in double quotes, so `AND`, `OR`, `NEAR`,
`*`, `-`, `col:` and quotes are only text and no query can make the search fail. All the words must match
(the porter tokenizer matches `coffees` for `coffee`). The query is shown escaped. Posting the form to
`POST /searches` remembers the words (the 10 last, newest first, as `Search.record` does), shows them on the
page, and redirects to the results; a get does not remember anything. There is no way to clear them yet.

## Avatars

`GET /users/TOKEN/avatar` answers with the picture of a user; TOKEN is a Rails `signed_id` for the purpose
`:avatar` (see [security.md](security.md)). The app makes no image. A user whose avatar Rails has
processed (`active_storage_attachments` named `avatar`, a row of `active_storage_variant_records` for its
blob, and the image attached to that variant record, a WebP) gets that file as it is on disk,
`image/webp`, with `Cache-Control: private, max-age=1800, stale-while-revalidate=604800`. If Rails has not
made the variant yet, the original image is sent with its own type (a plain `image/...`, never SVG):
unlike the variant, it is not resized and keeps its metadata (such as EXIF). A
user with no avatar at all gets an SVG with their initials, as Rails does for a person (a bot gets initials too, where
Rails has a picture for bots). A token that does not verify, a user that does not exist, and a file that
is missing are all the same `404`. The route needs a sign-in. Nothing in the app uploads an avatar yet.

## Assets

The folder `public/assets/` (`CAMPFIRE_ASSETS_DIR`) is served under `/assets/` without a sign-in. A name
with a fingerprint (`campfire-DIGEST.css`, DIGEST the first 16 hex digits of the SHA-256 of the file) is
sent with `Cache-Control: public, max-age=31536000, immutable`. When the CSS changes, rename it to its new
digest and change `Routes.STYLESHEET`; `specs/assets.feature` fails until the name is right. The same goes for the
script of the composer, `campfire-DIGEST.js` (`Routes.COMPOSER_SCRIPT`), which only the room page links: with it a
message is sent with `fetch` (the Turbo Stream answer above) and the page does not reload; without it the form posts
and redirects as before.

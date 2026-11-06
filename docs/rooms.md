# Rooms and messages

There are no live updates yet: a page shows what the database holds when it is asked for.

`GET /` sends a person who is in a room to the one they were in last, as Rails does (`WelcomeController`,
`TrackedRoomVisit`): a room page that is served (a `200` or a `304`, from the cache or not) sets the cookie `last_room` to
the room id for 20 years (`HttpOnly`, `SameSite=Lax`; it is not set again while it holds that room, and not by a `404`, the
settings or the older messages). With no cookie, or one for a room the person is not in, which no longer exists or is not
a number, home opens the oldest room they are in (by `created_at`, then id; any kind and any involvement). A person in no
room gets the welcome page. The cookie is `Secure` when `CAMPFIRE_SECURE_COOKIES=true`, as the session cookie is. It only chooses among the person's own rooms, so a forged one reveals nothing. A client that never sends it (the load generator of the benchmark) gets one `Set-Cookie` on every room page, as with Rails.

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

## Deleting a room

The person who made a room and an account administrator can delete it, of any kind (`DELETE /rooms/ID`, or the
`POST /rooms/ID` with `_method=delete` that Rails' forms send); another member is answered `403`, after the membership
check (a non-member is `404`). The settings page of a closed room ends with a "Delete room" button, a plain form post
that asks "Are you sure...?" when the page has scripting. As `Room#destroy_later` does, it works in two steps: one short
transaction closes an open room (a person who joins the account meanwhile is not let in) and deletes every membership,
so the room is gone from every sidebar and is a `404` at once, and then a task of the app deletes the messages one at a
time, each with its body, search row and boosts in a transaction of its own, so that other writes get through in
between, and last the room, with any message posted meanwhile. The request redirects to the home page without waiting
for the task. A step of the task that fails because the database is busy (no free connection in time, `database is
locked`) is tried again up to five times with a growing pause; if it still fails, or fails for any other reason, the
task logs it and stops, and so does a restart of the app in the middle. What is left of the room (closed, with nobody in
it, and the rest of its messages) stays in the database: nothing sweeps it. A post to a room that was deleted meanwhile
stores nothing and is a `404`. A `POST /rooms/ID` without `_method=delete` is a `405` with `Allow: GET, HEAD, POST, DELETE`, as is any other method.

## Settings

`/rooms/ID/settings` exists for open and closed rooms. The maker and an account administrator can rename the room; for a
closed room they can also add and remove people. Another member is answered `403` and sees no Settings link; a person who
is not in the room gets `404`, checked first. A direct room has no settings: it is the same `404`, before the form is
read, and it never converts.

A room converts the way Rails does it (`Rooms::OpensController#update`, `ClosedsController#update`): the form that is
saved says what the room is to be (the field `type`, `open` or `closed`; without it, or with another value, the room stays
what it is), and a link on the page draws the form of the other kind (`?type=closed` or `?type=open`). An open room saved
as closed keeps the people that the form does not take out (the page draws everyone checked); a closed room saved as open
gets every active person in it, and the ones who were in already keep their involvement. Both pages end with the button
that deletes the room.

The form never takes out the person who sends it. Saving applies only its own changes, so a stale form neither removes
someone added since nor brings back someone removed since. A person who is not active stays in. The update checks again,
inside its transaction, that the room is not a direct one and that the person may still change it, and rolls back
otherwise.

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

## Editing and deleting a message

The person who wrote a message and an account administrator can edit and delete it (`User#can_administer?` of Rails);
nobody else, even in a room that they are in. The heading of a message has an `Edit` link to
`/rooms/ID/messages/MID/edit` for those two people only, and the message is the same markup for everybody else. That page
holds the form in `<turbo-frame id="edit_message_MID">`: a textarea with the text of the message, a Save button
(`POST /rooms/ID/messages/MID` with `_method=patch`, or a real `PATCH`) and a Delete button that asks first
(`_method=delete`, or a real `DELETE`). A post to the message with any other `_method` is a `405` with
`Allow: POST, PATCH, DELETE`.

The text in the form is the plain text of the body: a body that this app stored (plain text made HTML) comes back exactly,
blank lines included; a body that Rails wrote with markup comes back as its plain text, without its formatting and blank
lines, and saving it stores that text. A save is cleaned and stored as a new message is (limits `Write something to send`
and 10000 characters, `422` with the form again), rewrites the body in `action_text_rich_texts` and the row of
`message_search_index`, and sets `updated_at` of the message and the room; it does not make the room unread. It redirects to the room
page. A delete removes the message with its body, its search row and its boosts in one transaction, and answers a Turbo
Stream that removes the message when `Accept` asks for one, else redirects to the room page. A person who is not in the
room, a message of another room, and a message that does not exist are all `404`, checked before the `403`. There are no
live updates yet (#52): other people see the change when they load the page.

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
`image/webp`, with `Cache-Control: private, max-age=1800, stale-while-revalidate=604800` and the `ETag` and `Last-Modified` of the file (a request with `If-None-Match` gets `304`). Rails says `public` there; the route needs a sign-in, so this keeps `private` and a shared cache never hands the picture to someone who is not signed in. If Rails has not
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

Bond sends each file with an `ETag` and `Last-Modified` (a request with `If-None-Match` or `If-Modified-Since` gets `304`), keeps the small ones in memory, and answers a client that takes gzip with the `.gz` file next to a text file when there is one that is not older. The Docker image writes one next to each stylesheet and script (`gzip -9 -k -n`); a run from the source folder has none and sends the plain file.

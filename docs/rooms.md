# Rooms and messages

A page shows what the database holds when it is asked for. The server also pushes what changes over `/cable`
([cable.md](cable.md)); the script of the page listens and applies it.

`GET /` sends a person who is in a room to the one they were in last, as Rails does (`WelcomeController`,
`TrackedRoomVisit`): a room page that is served (a `200` or a `304`, from the cache or not) sets the cookie `last_room` to
the room id for 20 years (`HttpOnly`, `SameSite=Lax`; it is not set again while it holds that room, and not by a `404`, the
settings or the older messages). With no cookie, or one for a room the person is not in, which no longer exists or is not
a number, home opens the oldest room they are in (by `created_at`, then id; any kind and any involvement). A person in no
room gets the welcome page. The cookie is `Secure` when `CAMPFIRE_SECURE_COOKIES=true`, as the session cookie is. It only chooses among the person's own rooms, so a forged one reveals nothing. A client that never sends it (the load generator of the benchmark) gets one `Set-Cookie` on every room page, as with Rails.

The sidebar lists the rooms that a person is in. The first run makes the open room "All Talk".

## Kinds

- **Open**: `New room` (any member may make one, unless the account restricts it, see below) puts every active person in it. A person who
  joins gets every open room that exists; a reactivated person gets the open rooms made while
  they were away.
- **Closed**: `New closed room` has a member picker (checkboxes of the active people). The maker is
  always in it, and only the chosen people get a membership, in one transaction.
- **Direct**: `New direct message` picks one or more people. The same people (the person included)
  open the direct message that exists instead of making a second one, even when forms arrive
  together. Each person sees it named after the others.

An administrator can let only administrators make a shared room (open or closed): the switch on the account page
(`PATCH /account`, field `account[settings][restrict_room_creation_to_administrators]`, `true` or `false`) is kept in the
JSON of `accounts.settings` as Rails keeps it, with the other keys left as they are. With it on, a member gets `403` on
`/rooms/new`, `/closed_rooms/new` and the posts to `/rooms` and `/closed_rooms` (before the form is read, as the filter
of Rails runs), and the sidebar leaves out the two links. A direct message is not restricted: Rails has no such filter
on `Rooms::DirectsController`. An empty or invalid `settings` is the default, everybody. Administrators are never
restricted.

Not yet: removing yourself.

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

## The sidebar setting

Every shared room page has a Sidebar link to `/rooms/ID/involvement` (`Rooms::InvolvementsController`), which shows
two choices of the person's own membership as radios, "Shown in the sidebar" and "Hidden from the sidebar", and saves
one with a `PUT` (a `POST` with `_method=put` from the form, in any case, or a real `PUT`) and the field `involvement`,
then goes back to the page. The route and the field are Rails' for parity; the values are `mentions` (shown, the default
level) and `invisible` (hidden). Notifications do not exist yet, so the other levels of Rails (`everything`,
`nothing`) are not offered: saving shown on a room that is hidden writes `mentions`, and on a room that is shown
already changes nothing, so a level that a Rails database holds is kept. The issues of push (#81) and mentions (#57)
bring the levels back to this page. A direct room has no choice and no link, as in Rails (its levels have no
`invisible`), so a conversation cannot be lost; its page says so. A value that the room does not offer is `422` with
the page again and nothing changed; a save with no field is `400`. A room that the person is not in is `404`, checked
first, and so is a save that finds the membership gone; any other method is `405` with Bond's `Allow` list.

There is no action for leaving a room, as in Rails: `invisible` takes the room out of the sidebar, and out of the
people that new messages notify, but its page is still reachable by URL and the person stays a member. Other members
are not affected.

## Messages

`/rooms/ID` shows the last 40 messages, the newest at the bottom, with an `Older messages` link to
the 40 before them (`?before=ID`). Messages are paged by `created_at` as Rails does, not by id: the
rows of a database that Rails seeded are not in the order of their time. `?before=ID` is the messages
before the time of message ID, and messages that share a time go by id.

A message is a row of `messages`, its HTML body in `action_text_rich_texts` (`record_type` `Message`,
`name` `body`) and its plain text in the FTS5 table `message_search_index` (`rowid` is the message id),
all written in one transaction. The form sends plain text of at most `CAMPFIRE_MAX_MESSAGE_LENGTH` characters (10000 by default), stripped of the
space around it, which is stored as HTML (escaped, a new line as `<br>`). An HTML body is cleaned by
`HtmlSanitizer.sanitize` before it is stored and when it is read: the body of a bot (the raw request body), a body that
Rails wrote, and the body of the form when it sends `message[format]=html` (the editor of Rails, Lexxy, sends HTML in
`message[body]` and has no such field; here the textarea of the page has no editor, so the field says which of the two
the body is, and without it the body is text). The tags of the editor stay (`strong`, `em`, `s`, `u`, `mark`,
headings, lists, `blockquote`, tables, `pre` and `code`), `script` and every attribute but a link's `href` go, and
`data-language` stays on a `pre` (the language of a code block, a short name). The URLs, the `www.` addresses and the
email addresses in the text of a message are links when it is shown, as Rails does (`MessagesHelper#auto_link_text`,
by `Autolink.link`): `<a target="_blank" href="..." rel="noopener noreferrer">`, none inside a link that is already
one. The stored body and the JSON of the bots API have no autolinks, as in Rails. There is no mention handling yet.

Each message on a page is `<div id="message_ID" data-message-id="ID">` with the author and the time, and its
body in `<div id="presentation_message_ID">` inside `<turbo-frame id="edit_message_ID">`, followed in the frame by its
boosts, `<div id="boosts_message_ID">` (see [Boosts](#boosts)); the list is
`<div id="messages_rooms_open_ID">` (`closed` or `direct` for the other types). `GET /rooms/ID/messages` is
the same markup without the layout or the sidebar: the 40 messages before `?before=ID` (the newest 40 without
it), `204` when there are none, `404` for a room that is not the person's. Every page links one fingerprinted
stylesheet, `/assets/campfire-DIGEST.css` (see [Assets](#assets)).

In the browser, the script of the page also follows the `Older messages` link by scrolling: the 40 messages before the
first one are loaded above the list when the link comes near the top, with the reader's place kept, and on a page that
does not end at the newest message `Latest messages` does the same below it with `?after=` (`DESIGN.md`, "Script").
An answer that is a redirect (a signed-out session) or a page with nothing new in it is not inserted, and the link goes
or stays; a lost connection, a 5xx or a 429 is tried again 3 times (a `Retry-After` is honoured) and then the pager
waits for the browser to be online or for the reader to scroll to the link. When the walk down reaches the newest
message the page is the latest one, and the script fetches the room page once (`/rooms/ID`) for what was created
meanwhile; the catch-up after a reconnect does the same and, whatever address the page has, treats the messages from the
oldest fetched one that the list has on as covered, by position, not by id (an id does not follow time in a database
that Rails seeded). Each
`<time datetime>` is shown in the viewer's zone; the server's UTC clock is the text of a page without the script.

`?after=ID` on the same route is the 40 messages after message ID, oldest first, `204` when there are none; with both
cursors, `before` wins, as in Rails. A cursor that is not a number is `400`. One that names no message of the room (a
message deleted since the client got it, or one of another room) stands for the nearest message of the room by id, on
the side of the walk, and the page includes that message, so the pager walks on; `204` when there is none.
`/rooms/ID/@MESSAGE` is the room page around a message (`page_around`): the 40 before it, it, and the 40 after, with
`Older messages` and `Latest messages` links where the window does not reach the first or the last message. A message
that the room does not have shows the newest page, as in Rails; a segment that is not `@` and a number is `404`. Bond's
route params are whole segments, so the route is `/rooms/:id/:segment` (a literal segment such as `messages` wins), which
also makes `POST` to another path under a room a `405` where it was a `404`. That page, like the room page with
`?before=`, is not kept in the cache, since there is one for every message; `?after=` is kept like `?before=`.

`GET /rooms/ID/refresh?since=MILLISECONDS` is how a client catches up after a lost connection: Turbo Streams that
append the messages created after that time (the first 40, oldest first) to the list, and a replace for each other
message edited after it (the newest 40). A message created since but past the first 40 is a replace too (the client has
nothing to replace, so it ignores it), as in Rails. `since` is read as Ruby's `to_i` reads it (`12abc` is 12, `1.5e3`
is 1): none, or no digits at the start, or a time before the epoch, is the epoch. The time is compared as text with the
columns (`2026-03-01 09:00:00.123000`), and with `>=` where Rails has `>`: a client keeps the time in milliseconds, so
a second message made in the same millisecond as the last one it saw would be skipped. The message that the client
has comes again, and a Turbo Stream that appends or replaces an id that is in the page puts the new one in its place.

The room page, the page of older messages, the sidebar page (`GET /users/me/sidebar`) and the search page are kept
whole in a cache (`CAMPFIRE_RESPONSE_CACHE_MB`, 64 by default, 0 for none); Rails Campfire keeps `rooms#show` and
`messages#index`. A page is kept for one person and one room and `?before=` (the sidebar for one person, the search
for one query), so nobody is sent a page that was made for somebody else, and only a 200 is kept. The room page and the
sidebar have a key with the version of the database in it; the search and the older messages have a place of the
person and keep the version in the page (see below). The words of a
search are the person's to choose, so a person keeps at most `CAMPFIRE_SEARCH_PAGES` search pages (8 by default; the
words choose the place, and a query of another place or version is written over), and words longer than the form
allows are not kept. The `?before=` and `?after=` pages of older messages are also keyed by a number that the person
chooses, so a person keeps at most `CAMPFIRE_CURSOR_PAGES` pages of each of the two (16 by default; the room and the
cursor choose the place, and a page of another cursor, room or version is written over; two cursors in one place take
turns, and nothing worse happens). The people of the sessions are in a store of their own
(`CAMPFIRE_SESSION_CACHE_MB`, 4 by default), so that no number of pages pushes a session out. A kept person is valid
for one version of the database and until their session ends (30 days after it began, which no commit announces). A
page is valid for one version of the database: a connection of its own reads `PRAGMA data_version`, which changes
whenever any connection or program commits (a new message, an edit, a delete, a change of members, a rename of the room
or of a person), and the version is in the key or the page, so the next request builds the page again. Every page has a weak `ETag`
(a digest of its bytes) and `Cache-Control: max-age=0, private, must-revalidate`, and a request with `If-None-Match` of
that tag is answered `304`. The `client_message_id` of the form is drawn when a page is made, so two loads at one
version share it; the app stores it and does nothing else with it. The same version also keeps the person of a session:
a read request with a session cookie reads the version first and finds the person in the cache of the version, so a hit
takes one quick read of the observer's connection and none of the pool. A hit does not touch the session, so on a quiet database
`last_active_at` can be older than its five-minute refresh (only Rails reads it; the end of a session uses
`created_at`). A sign-out, a deactivation, a ban, a rename and a change of role are commits, so the next read has a new
version and looks the session up again. The cache of messages (`CAMPFIRE_CACHE_MB`) is separate: it saves rendering a
message again when the page is built. The sidebar and the search send the weak `ETag` and `Cache-Control: max-age=0,
private, must-revalidate` and answer `304` to `If-None-Match` even with the cache off.

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
and `CAMPFIRE_MAX_MESSAGE_LENGTH` characters, `422` with the form again), rewrites the body in `action_text_rich_texts` and the row of
`message_search_index`, and sets `updated_at` of the message and the room; it does not make the room unread. It redirects to the room
page. A delete removes the message with its body, its search row and its boosts in one transaction, and answers a Turbo
Stream that removes the message when `Accept` asks for one, else redirects to the room page. A person who is not in the
room, a message of another room, and a message that does not exist are all `404`, checked before the `403`. There are no
live updates yet (#52): other people see the change when they load the page.

## Boosts

A person who is in a room can boost any message of it (`Messages::BoostsController`): a reaction under the message, one
of the eight quick ones (👍 👏 👋 💪 ❤️ 😂 🎉 🔥, `EmojiHelper::REACTIONS`) or words of the person's own, 1 to 16
characters once the space around them is taken off (the column is `varchar(16)`, which SQLite does not enforce, so the
app does; Rails checks the length only in its form). Every message has the link "Boost" in its `<div
id="boosts_message_ID">`, after the boosts it has, oldest first, each a `<div id="boost_ID" data-booster-id="USER">`
with the name of the booster, the text and a form that takes it away. That form is hidden by the stylesheet except on
the boosts of the person who looks (the room page has a rule for them, as it has for the side of the bubbles), because
the markup is the same for everybody. Words are shown as text. The routes are Rails':

| Request | Answer |
|---|---|
| `GET /messages/ID/boosts` | the `<div id="boosts_message_ID">` of the message, as the room page has it |
| `GET /messages/ID/boosts/new` | a page with the eight reactions, each a button of one form, and a field for words |
| `POST /messages/ID/boosts` | the field `boost[content]` adds one: a redirect to the room page around the message (Rails redirects to the list, which is only a frame); `422` with the page again for a text that is blank or too long, `400` with no field |
| `DELETE /messages/ID/boosts/BID`, or a `POST` with `_method=delete` | takes the boost off and redirects the same way |

A request that asks for `text/vnd.turbo-stream.html` (the script of the room page does) is answered `200` with the Turbo
Stream that appends the boost to `boosts_message_ID`, or removes `boost_BID`. A message is reached through the
membership of its room, any kind and involvement (`User#reachable_messages`): a message of a room the person is not in,
one that does not exist and an id that is not a number are the same `404`, checked before the form is read. Only the
booster takes a boost away; for anybody else, an administrator or the author of the message included, and for a boost of
another message or one that is gone, it is `404` and nothing changes (Rails' `find_by!`). Any other method on a boost
is `405` with `Allow: POST, DELETE`. A boost touches its message and the room, on adding and on removing it (Rails'
`touch: true`), so the refresh of the room (`/rooms/ID/refresh`) hands the message out again, the key of the cached
markup of the message changes, and so does the version of the database that the page cache keys on. The key also holds
the boosts themselves, so a boost written by another program, with no `updated_at`, shows at once too. A message has no
cap on its boosts, as in Rails, and a person may boost it more than once. Deleting a message deletes its boosts. The boosts of a chat bot are in [people.md](people.md#the-messages-api).

The script of the room page opens the page of a new boost under the message instead of going to it (the reactions, a
field for words, Esc or Cancel to close), posts with `fetch` and applies the Turbo Stream. Live, everybody who looks at
the room gets the boost appended and removed over `/cable` ([cable.md](cable.md)).

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
page, and redirects to the results; a get does not remember anything. `DELETE /searches/clear` (or a `POST` with
`_method=delete`, which is the button under the list, with a confirmation) removes every recent search of the person who is
signed in, and no one else's, and redirects to `/searches`; any other method is a 405 (`Allow: POST, DELETE`). The page
links back to the room the person was in last (`Back to the room`: the room of the `last_room` cookie when they are in
it, else the oldest of their rooms, as `last_room_visited` does; a person in no room gets no link). The kept search page
holds the cookie in its stamp, and a clear is a commit, so a kept page never shows searches that were cleared or a stale
link.

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
What the database says (the initials, or the file and its type) is kept in the cache of whole pages for one version of
the database, so any commit, such as a new or a removed picture, makes the next request ask again; a repeat takes no
connection of the pool. The file is read each time, so a file that has gone from the disk is still a `404`.

## Assets

The folder `public/assets/` (`CAMPFIRE_ASSETS_DIR`) is served under `/assets/` without a sign-in. A name
with a fingerprint (`campfire-DIGEST.css`, DIGEST the first 16 hex digits of the SHA-256 of the file) is
sent with `Cache-Control: public, max-age=31536000, immutable`. `make assets` builds the files from `app/` (Dart Sass and
esbuild) and writes the names to `src/campfire_web/asset_names.agc`, which `Routes.STYLESHEET` and `Routes.SCRIPT` read;
`specs/assets.feature` checks that each name has the digest of its file. The script of the composer, `campfire-DIGEST.js`, which the room page, the page that edits a message and the
pages with the sidebar link: with it a message is sent with `fetch` (the Turbo Stream answer above) and the page does not
reload, and the keys work (Enter, Shift+Enter, Ctrl or Cmd+Enter, Esc); without it the form posts and redirects as before.

Every HTML page and every redirect that sets no `Cache-Control` of its own (`web.agc`, `revalidate`) is sent with `Cache-Control: max-age=0, private, must-revalidate`, as Rails does, so a browser never shows an old page that links an old fingerprint after a deploy.

Bond sends each file with an `ETag` and `Last-Modified` (a request with `If-None-Match` or `If-Modified-Since` gets `304`), keeps the small ones in memory, and answers a client that takes gzip with the `.gz` file next to a text file when there is one that is not older. The Docker image writes one next to each stylesheet and script (`gzip -9 -k -n`); a run from the source folder has none and sends the plain file.

## Installable app

Every page links a manifest, `/webmanifest.json`, named after the account ("Campfire" before the first run), so a browser can install the app, as Rails' `PwaController` does. Its icons are `/account/logo` (512 pixels) and `/account/logo?size=small` (192), the stock icons of Rails (`public/assets/app-icon.png` and `app-icon-192.png`) until an account can have a logo of its own, sent with `Cache-Control: max-age=300, public, stale-while-revalidate=604800`. The script of the pages registers the service worker, `/service-worker.js`, which keeps the fingerprinted stylesheet and script and answers them from its cache; every other request (a page, a form, the bots API, an icon, `/cable`) goes to the network and is never kept. The three paths need no sign-in. Web Push, the shortcuts and screenshots of Rails' manifest and its install help are not there yet.

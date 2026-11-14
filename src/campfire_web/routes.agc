## The paths of the pages, in one place so that the router, the filter, the redirects and the forms of the views name
## the same ones.

import URI from "std/uri"
import AssetNames from "asset_names"

HOME = "/"
FIRST_RUN = "/first_run"
SIGN_IN = "/session/new"
SESSION = "/session"
## Signing in on another device (`TransfersWeb`): the post that makes a link, the link (its page, and the `PUT` that uses
## it, or a `POST` with `_method` set to `put`; any other `POST` is a 405 that lists `SESSION_TRANSFER_ALLOW`), and the QR
## code of a Base64url text.
SESSION_TRANSFERS = "/session/transfers"
SESSION_TRANSFER = "/session/transfers/:id"
SESSION_TRANSFER_ALLOW = "GET, HEAD, POST, PUT"
QR_CODE = "/qr_code/:id"
SIGN_OUT = "/sign_out"
HEALTH = "/health"
## The Action Cable WebSocket (the path that the Rails client and the benchmark connect to). It is public for the
## sign-in filter, which would answer the handshake with a 302 (the client retries in a loop): the connection looks up
## the session itself and refuses with a `disconnect`.
CABLE = "/cable"
## The counts of the hub of `/cable`, as JSON, for an administrator.
CABLE_STATS = "/cable/stats"
## The page that Rails answers at `/up` (the check of its load balancers and of the benchmark harness): green.
UP = "/up"
## The installable web app (`PwaWeb`): the manifest, the service worker and the icon of the account. None needs a
## sign-in.
WEBMANIFEST = "/webmanifest.json"
SERVICE_WORKER = "/service-worker.js"
ACCOUNT_LOGO = "/account/logo"
## What every 404 of the app says: a path with no route, and a room, a person or a join code that a visitor may not know
## of, so no 404 tells which of them it is.
MISSING = "Not Found"
## The stylesheet that every page links, a fingerprinted file of `public/assets/` (the name has the first 16 hex digits
## of the SHA-256 of the file: `specs/assets.feature` checks it). `make assets` builds it from `app/assets/stylesheets/`
## and writes the name to `asset_names.agc`, so nobody renames it by hand. The benchmark reads the link out of the room
## page (`/assets/....css`), and the folder is served under `ASSETS`.
ASSETS = "/assets"
STYLESHEET = AssetNames.STYLESHEET
## The script of the pages (the composer of the room page sends with `fetch`, and every page with the sidebar listens to
## `/cable`), fingerprinted like the stylesheet. The room page and the pages with the sidebar link it; they work without.
SCRIPT = AssetNames.SCRIPT
## The sidebar of the person who is signed in as a document of its own (the frame that Rails loads in the page), the
## search of messages (a `GET` shows the results of `?q=`, a `POST` with `q` remembers the query and goes to them) and
## the avatar of a user, whose `:id` is not an id but `user.signed_id(purpose: :avatar)` (the router wants one name for
## the segment under `/users/`).
SIDEBAR = "/users/me/sidebar"
## The people that a mention may name (`AutocompletableWeb`): the prompt items of the editor, and the same list as JSON.
AUTOCOMPLETE_USERS = "/autocompletable/users"
AUTOCOMPLETE_USERS_JSON = "/autocompletable/users.json"
SEARCHES = "/searches"
## Forgets the recent searches of the person who is signed in (`clear` of Rails' `SearchesController`): a `DELETE`, or a
## `POST` with `_method` set to `METHOD_DELETE`, which is Rails' button. Any other `POST` is a 405 that lists
## `SEARCHES_CLEAR_ALLOW`, which is the list that Bond itself gives for the path (a `GET`, `PUT` or `PATCH` is its 405).
SEARCHES_CLEAR = "/searches/clear"
SEARCHES_CLEAR_ALLOW = "POST, DELETE"
AVATAR = "/users/:id/avatar"
## The same path takes the removal of the picture of the person who is signed in (`:id` is `me`, or their id; another
## user's picture is a 404): a `DELETE`, or a `POST` with `_method` set to `METHOD_DELETE`, which is Rails' button. Any
## other `POST` is a 405 that lists `AVATAR_ALLOW`, which is Bond's own list for the path.
AVATAR_ALLOW = "GET, HEAD, POST, DELETE"
## The password reset: the form for the email, the post that asks for the link, the page of the link (with `?token=`)
## and the post that sets the new password.
PASSWORD_RESET_NEW = "/password_reset/new"
PASSWORD_RESET = "/password_reset"
PASSWORD_RESET_EDIT = "/password_reset/edit"
PASSWORD_RESET_UPDATE = "/password_reset/confirm"
## The rooms: the form of a new one, the post that makes it, a room page (with `?before=ID` for the messages before
## that one) and the messages of a room: a `GET` gives the fragment of the 40 before `?before=ID` (without the layout, for
## the script that loads older messages) and a `POST` stores one. `:id` is the id of the room.
ROOMS = "/rooms"
ROOM_NEW = "/rooms/new"
ROOM = "/rooms/:id"
ROOM_MESSAGES = "/rooms/:id/messages"
## `/rooms/:id` takes the form that deletes a room: a `POST` with the field `_method` set to `delete`, as the forms of
## Rails send it (a browser form cannot send `DELETE`), and a real `DELETE`. A `POST` without it, and any other method,
## is a 405 that lists the methods of the path (`ROOM_ALLOW`, which is the list that Bond itself gives for the path).
ROOM_ALLOW = "GET, HEAD, POST, DELETE"
## One message of a room and the page that edits it (`:id` is the room and `:message_id` the message). The page of the
## message takes `PATCH`, which saves the edit, and `DELETE`, and as a `POST` with `_method` set to one of the two
## `METHOD_` names, as Rails' forms send them (a browser form cannot send either); any other `POST` is a 405 that lists
## `ROOM_MESSAGE_ALLOW`.
ROOM_MESSAGE = "/rooms/:id/messages/:message_id"
ROOM_MESSAGE_EDIT = "/rooms/:id/messages/:message_id/edit"
## The file of a message, for the people of its room (`rails_blob_path` of Rails, which is a signed link instead).
ROOM_MESSAGE_ATTACHMENT = "/rooms/:id/messages/:message_id/attachment"
ROOM_MESSAGE_ALLOW = "POST, PATCH, DELETE"
METHOD_PATCH = "patch"
METHOD_DELETE = "delete"
## The forms of a closed room and of a direct message, and the posts that make them (each makes a room and goes to its
## page), and the settings of an open or closed room: its form and the post that saves it. Both take `type`, the kind
## of room to be (`SETTINGS_OPEN` or `SETTINGS_CLOSED`); without it, or with another value, the room stays what it is.
SETTINGS_OPEN = "open"
SETTINGS_CLOSED = "closed"
CLOSED_ROOM_NEW = "/closed_rooms/new"
CLOSED_ROOMS = "/closed_rooms"
DIRECT_ROOM_NEW = "/direct_rooms/new"
DIRECT_ROOMS = "/direct_rooms"
ROOM_SETTINGS = "/rooms/:id/settings"
## `/rooms/:id/refresh?since=MILLISECONDS` gives the Turbo Streams of what a room gained since a time, and
## `/rooms/:id/@MESSAGE` is the room page around a message. Bond's params are whole segments, so the second is the route
## `ROOM_AT` that takes any segment after the room (a literal one, such as `messages`, is tried first), and the handler
## checks that it is `AT_PREFIX` and a number. The bots' messages API has a segment there too, the key of the bot, so
## both routes name it `:segment` (Bond wants one name for a place).
ROOM_REFRESH = "/rooms/:id/refresh"
ROOM_AT = "/rooms/:id/:segment"
AT_PREFIX = "@"
## The messages API of the chat bots (`Messages::ByBotsController`): the key of the bot (`ID-TOKEN`) is in the path and
## is the whole login, so these are not behind the sign-in filter (`AuthWeb.bot_api?`). A `GET` of `BOT_MESSAGES` lists
## the room (`?before=ID`, `?after=ID`), a `POST` posts the raw body, and a `PATCH` or `PUT` and a `DELETE` of
## `BOT_MESSAGE` (`:message_id`) change a message of the bot.
BOT_MESSAGES = "/rooms/:id/:segment/messages"
BOT_MESSAGE = "/rooms/:id/:segment/messages/:message_id"
## The boosts of the bots (`Messages::Boosts::ByBotsController`), under a message: a `POST` of `BOT_MESSAGE_BOOSTS`
## boosts it with the raw body as the text, and a `DELETE` of `BOT_MESSAGE_BOOST` (`:boost_id`) takes a boost of the
## bot off.
BOT_MESSAGE_BOOSTS = "/rooms/:id/:segment/messages/:message_id/boosts"
BOT_MESSAGE_BOOST = "/rooms/:id/:segment/messages/:message_id/boosts/:boost_id"
## The boosts of a message (`Messages::BoostsController`; `:message_id` is the message, whatever its room): a `GET` of
## `MESSAGE_BOOSTS` gives their markup and a `POST` adds one (the field `boost[content]`), `MESSAGE_BOOST_NEW` is the
## page that adds one, and a `DELETE` of `MESSAGE_BOOST` (`:id`), or a `POST` with `_method` set to `METHOD_DELETE`,
## takes a boost off, for its booster alone. Any other method on a boost is a 405 that lists `MESSAGE_BOOST_ALLOW`.
MESSAGE_BOOSTS = "/messages/:message_id/boosts"
MESSAGE_BOOST_NEW = "/messages/:message_id/boosts/new"
MESSAGE_BOOST = "/messages/:message_id/boosts/:id"
MESSAGE_BOOST_ALLOW = "POST, DELETE"
## The sidebar setting of a person for a room (`:id` is the room): the page that shows the choice and its form, and
## the save, a `PUT` or a `POST` with `_method` set to `METHOD_PUT` (as Rails' forms send it), with the field
## `involvement`. Any other method is a 405 that lists `ROOM_INVOLVEMENT_ALLOW`, which is Bond's own list for the path.
ROOM_INVOLVEMENT = "/rooms/:id/involvement"
ROOM_INVOLVEMENT_ALLOW = "GET, HEAD, POST, PUT"
METHOD_PUT = "put"
## The page of a user (`:id` is their id; any signed-in person may read it) and the profile of the person who is signed
## in: the page that shows their form, and the save of it, a `PATCH` or a `PUT` or a `POST` with `_method` set to one
## of the `METHOD_` names (as Rails' forms send it). `:id` is `me` in the links, as in Rails, and is the id of the
## person too; the profile of another user is a 404 here, so it is only read on their page. Any other method is a 405
## that lists `PROFILE_ALLOW`, which is Bond's own list for the path.
USER = "/users/:id"
PROFILE = "/users/:id/profile"
PROFILE_ALLOW = "GET, HEAD, POST, PATCH, PUT"
## The ban of a user (`:id` is the user): a `POST` bans them and a `DELETE`, or a `POST` with `_method` set to
## `METHOD_DELETE`, lifts the ban. Any other method is a 405 that lists `USER_BAN_ALLOW`.
USER_BAN = "/users/:id/ban"
USER_BAN_ALLOW = "POST, DELETE"
## The join link of the account: its page and the post of its form, which is the same path, with the join code as
## `:code`. It is the one page besides the sign-in ones that needs no session (see `AuthWeb.public?`).
JOIN = "/join/:code"
## The account settings page (`/account/edit`), the save of its name (`PATCH /account`, or a `POST` with `_method` set
## to `patch`, as Rails' forms send it) and the person under the account (`:id` is the user): `PATCH` sets the role,
## `DELETE` removes the person (deactivates, as Rails' `User#deactivate` does), and a `POST` with `_method` does
## either. Any other method is a 405 that lists the methods of the path (`ACCOUNT_ALLOW`, `ACCOUNT_USER_ALLOW`: Bond's
## own lists).
ACCOUNT_EDIT = "/account/edit"
ACCOUNT = "/account"
ACCOUNT_ALLOW = "POST, PATCH"
ACCOUNT_USER = "/account/users/:id"
ACCOUNT_USER_ALLOW = "POST, PATCH, DELETE"
## The chat bots of the account, for administrators (`Accounts::BotsController`): the list and the post that makes a bot,
## the form of a new one, a bot (`:id`; a `PATCH` or `PUT` renames it, a `DELETE` deactivates it, and a `POST` with
## `_method` set to one of the `METHOD_` names does the same, as Rails' forms send it), the page that edits it, and its
## key (`Accounts::Bots::KeysController`: a `PUT`, or a `POST` with `_method` `put`, makes a new one). Any other method
## on a bot or its key is a 405 that lists `BOT_ALLOW` or `BOT_KEY_ALLOW`, which are Bond's own lists for the paths.
BOTS = "/account/bots"
BOT_NEW = "/account/bots/new"
BOT = "/account/bots/:id"
BOT_EDIT = "/account/bots/:id/edit"
BOT_KEY = "/account/bots/:id/key"
BOT_ALLOW = "POST, PATCH, PUT, DELETE"
BOT_KEY_ALLOW = "POST, PUT"
## The people page, the posts that deactivate and reactivate a person (`:id` is the id of the user), and the post that
## makes a new join code.
USERS = "/users"
USER_DEACTIVATE = "/users/:id/deactivate"
USER_REACTIVATE = "/users/:id/reactivate"
JOIN_CODE = "/account/join_code"

## The path of the results of a search for `query`, the words that `Searches.words` made.
def search_path(query: String) -> String = "/searches?q=#{URI.encode_www_form_component(query)}"

## The path of the room page.
def room_path(room_id: Int) -> String = "/rooms/#{room_id}"

## The path of the page of the messages that come before `before` in the room.
def room_before_path(room_id: Int, before: Int) -> String = "/rooms/#{room_id}?before=#{before}"

## The path that a message of the room is posted to.
def room_messages_path(room_id: Int) -> String = "/rooms/#{room_id}/messages"

## The path of a message, which is where its edit form posts.
def room_message_path(room_id: Int, message_id: Int) -> String = "/rooms/#{room_id}/messages/#{message_id}"

## The path of the page that edits a message.
def room_message_edit_path(room_id: Int, message_id: Int) -> String = "/rooms/#{room_id}/messages/#{message_id}/edit"

## The path of the file of a message.
def room_message_attachment_path(room_id: Int, message_id: Int) -> String
  "/rooms/#{room_id}/messages/#{message_id}/attachment"
end

## The path of the boosts of a message, which is where a boost is added.
def message_boosts_path(message_id: Int) -> String = "/messages/#{message_id}/boosts"

## The path of the page that adds a boost to a message.
def message_boosts_new_path(message_id: Int) -> String = "/messages/#{message_id}/boosts/new"

## The path of a boost, which is where its removal posts.
def message_boost_path(message_id: Int, boost_id: Int) -> String = "/messages/#{message_id}/boosts/#{boost_id}"

## The path of the settings of an open or closed room, which is also where its form posts.
def room_settings_path(room_id: Int) -> String = "/rooms/#{room_id}/settings"

## The path of the sidebar setting of a room, which is also where their form posts.
def room_involvement_path(room_id: Int) -> String = "/rooms/#{room_id}/involvement"

## The path of the settings drawn as the form of `kind` (`open` or `closed`), which is how a room is converted: the form
## that is saved says what the room is to be (`SETTINGS_OPEN`, `SETTINGS_CLOSED`).
def room_settings_kind_path(room_id: Int, kind: String) -> String = "/rooms/#{room_id}/settings?type=#{kind}"

## The path of the room page around a message.
def room_at_path(room_id: Int, message_id: Int) -> String = "/rooms/#{room_id}/@#{message_id}"

## The path of the changes of a room since `millis`.
def room_refresh_path(room_id: Int, millis: Int) -> String = "/rooms/#{room_id}/refresh?since=#{millis}"

## The path of the messages API of the bot with this key in a room.
def bot_messages_path(room_id: Int, key: String) -> String = "/rooms/#{room_id}/#{key}/messages"

## The icon of the account: the 192 pixel one when `small`, else the 512 pixel one.
def account_logo_path(small: Bool) -> String
  return "#{ACCOUNT_LOGO}?size=small" if small

  ACCOUNT_LOGO
end

## The link that signs a browser in with the transfer token `token`.
def session_transfer_path(token: String) -> String = "#{SESSION_TRANSFERS}/#{token}"

## The path of the join page of this code, which is also where its form posts.
def join_path(code: String) -> String = "/join/#{code}"

## The path of a person under the account, which is where the forms of their role and of their removal post.
def account_user_path(user_id: Int) -> String = "/account/users/#{user_id}"

## The path of a bot, which is where its forms post, and of the page that edits it and of its key.
def bot_path(bot_id: Int) -> String = "/account/bots/#{bot_id}"

## The path of the page that edits a bot.
def bot_edit_path(bot_id: Int) -> String = "/account/bots/#{bot_id}/edit"

## The path that makes a new key for a bot.
def bot_key_path(bot_id: Int) -> String = "/account/bots/#{bot_id}/key"

## The path of the page of a user.
def user_path(user_id: Int) -> String = "/users/#{user_id}"

## The path of the profile of the person who is signed in, which is also where its form posts.
def profile_path() -> String = "/users/me/profile"

## The path of the picture of the person who is signed in, which is where the button that removes it posts.
def own_avatar_path() -> String = "/users/me/avatar"

## The path of the ban of this user, which is where the forms of the ban and of its lifting post.
def user_ban_path(user_id: Int) -> String = "/users/#{user_id}/ban"

## The path that deactivates this user.
def user_deactivate_path(user_id: Int) -> String = "/users/#{user_id}/deactivate"

## The path that reactivates this user.
def user_reactivate_path(user_id: Int) -> String = "/users/#{user_id}/reactivate"

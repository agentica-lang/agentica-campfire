## The paths of the pages, in one place so that the router, the filter, the redirects and the forms of the views name
## the same ones.

import URI from "std/uri"

export HOME = "/"
export FIRST_RUN = "/first_run"
export SIGN_IN = "/session/new"
export SESSION = "/session"
export SIGN_OUT = "/sign_out"
export HEALTH = "/health"

## The Action Cable WebSocket (the path that the Rails client and the benchmark connect to). It is public for the
## sign-in filter, which would answer the handshake with a 302 (the client retries in a loop): the connection looks up
## the session itself and refuses with a `disconnect`.
export CABLE = "/cable"

## The counts of the hub of `/cable`, as JSON, for an administrator.
export CABLE_STATS = "/cable/stats"

## The page that Rails answers at `/up` (the check of its load balancers and of the benchmark harness): green.
export UP = "/up"

## What every 404 of the app says: a path with no route, and a room, a person or a join code that a visitor may not know
## of, so no 404 tells which of them it is.
export MISSING = "Not Found"

## The stylesheet that every page links, a fingerprinted file of `public/assets/` (the name has the first 16 hex digits
## of the SHA-256 of the file: `specs/assets.feature` checks it, so a change to the file renames it and this). The
## benchmark reads the link out of the room page (`/assets/....css`), and the folder is served under `ASSETS`.
export ASSETS = "/assets"
export STYLESHEET = "/assets/campfire-65c285f24a690567.css"

## The script of the room page (the composer sends with `fetch`) and of the page that edits a message (the keys),
## fingerprinted like the stylesheet. Only those two link it; they work without it.
export COMPOSER_SCRIPT = "/assets/campfire-17fc68f2137508ec.js"

## The sidebar of the person who is signed in as a document of its own (the frame that Rails loads in the page), the
## search of messages (a `GET` shows the results of `?q=`, a `POST` with `q` remembers the query and goes to them) and
## the avatar of a user, whose `:id` is not an id but `user.signed_id(purpose: :avatar)` (the router wants one name for
## the segment under `/users/`).
export SIDEBAR = "/users/me/sidebar"
export SEARCHES = "/searches"
export AVATAR = "/users/:id/avatar"

## The password reset: the form for the email, the post that asks for the link, the page of the link (with `?token=`)
## and the post that sets the new password.
export PASSWORD_RESET_NEW = "/password_reset/new"
export PASSWORD_RESET = "/password_reset"
export PASSWORD_RESET_EDIT = "/password_reset/edit"
export PASSWORD_RESET_UPDATE = "/password_reset/confirm"

## The rooms: the form of a new one, the post that makes it, a room page (with `?before=ID` for the messages before
## that one) and the messages of a room: a `GET` gives the fragment of the 40 before `?before=ID` (without the layout, for
## the script that loads older messages) and a `POST` stores one. `:id` is the id of the room.
export ROOMS = "/rooms"
export ROOM_NEW = "/rooms/new"
export ROOM = "/rooms/:id"
export ROOM_MESSAGES = "/rooms/:id/messages"

## `/rooms/:id` takes the form that deletes a room: a `POST` with the field `_method` set to `delete`, as the forms of
## Rails send it (a browser form cannot send `DELETE`), and a real `DELETE`. A `POST` without it, and any other method,
## is a 405 that lists the methods of the path (`ROOM_ALLOW`, which is the list that Bond itself gives for the path).
export ROOM_ALLOW = "GET, HEAD, POST, DELETE"

## One message of a room and the page that edits it (`:id` is the room and `:message_id` the message). The page of the
## message takes `PATCH`, which saves the edit, and `DELETE`, and as a `POST` with `_method` set to one of the two
## `METHOD_` names, as Rails' forms send them (a browser form cannot send either); any other `POST` is a 405 that lists
## `ROOM_MESSAGE_ALLOW`.
export ROOM_MESSAGE = "/rooms/:id/messages/:message_id"
export ROOM_MESSAGE_EDIT = "/rooms/:id/messages/:message_id/edit"
export ROOM_MESSAGE_ALLOW = "POST, PATCH, DELETE"
export METHOD_PATCH = "patch"
export METHOD_DELETE = "delete"

## The forms of a closed room and of a direct message, and the posts that make them (each makes a room and goes to its
## page), and the settings of an open or closed room: its form and the post that saves it. Both take `type`, the kind
## of room to be (`SETTINGS_OPEN` or `SETTINGS_CLOSED`); without it, or with another value, the room stays what it is.
export SETTINGS_OPEN = "open"
export SETTINGS_CLOSED = "closed"
export CLOSED_ROOM_NEW = "/closed_rooms/new"
export CLOSED_ROOMS = "/closed_rooms"
export DIRECT_ROOM_NEW = "/direct_rooms/new"
export DIRECT_ROOMS = "/direct_rooms"
export ROOM_SETTINGS = "/rooms/:id/settings"

## `/rooms/:id/refresh?since=MILLISECONDS` gives the Turbo Streams of what a room gained since a time, and
## `/rooms/:id/@MESSAGE` is the room page around a message. Bond's params are whole segments, so the second is the route
## `ROOM_AT` that takes any segment after the room (a literal one, such as `messages`, is tried first), and the handler
## checks that it is `AT_PREFIX` and a number.
export ROOM_REFRESH = "/rooms/:id/refresh"
export ROOM_AT = "/rooms/:id/:at"
export AT_PREFIX = "@"

## The sidebar setting of a person for a room (`:id` is the room): the page that shows the choice and its form, and
## the save, a `PUT` or a `POST` with `_method` set to `METHOD_PUT` (as Rails' forms send it), with the field
## `involvement`. Any other method is a 405 that lists `ROOM_INVOLVEMENT_ALLOW`, which is Bond's own list for the path.
export ROOM_INVOLVEMENT = "/rooms/:id/involvement"
export ROOM_INVOLVEMENT_ALLOW = "GET, HEAD, POST, PUT"
export METHOD_PUT = "put"

## The page of a user (`:id` is their id; any signed-in person may read it) and the profile of the person who is signed
## in: the page that shows their form, and the save of it, a `PATCH` or a `PUT` or a `POST` with `_method` set to one of
## the `METHOD_` names (as Rails' forms send it). `:id` is `me` in the links, as in Rails, and is the id of the person
## too; the profile of another user is a 404 here, so it is only read on their page. Any other method is a 405 that lists
## `PROFILE_ALLOW`, which is Bond's own list for the path.
export USER = "/users/:id"
export PROFILE = "/users/:id/profile"
export PROFILE_ALLOW = "GET, HEAD, POST, PATCH, PUT"

## The join link of the account: its page and the post of its form, which is the same path, with the join code as
## `:code`. It is the one page besides the sign-in ones that needs no session (see `AuthWeb.public?`).
export JOIN = "/join/:code"

## The account settings page (`/account/edit`), the save of its name (`PATCH /account`, or a `POST` with `_method` set
## to `patch`, as Rails' forms send it) and the person under the account (`:id` is the user): `PATCH` sets the role,
## `DELETE` removes the person (deactivates, as Rails' `User#deactivate` does), and a `POST` with `_method` does
## either. Any other method is a 405 that lists the methods of the path (`ACCOUNT_ALLOW`, `ACCOUNT_USER_ALLOW`: Bond's
## own lists).
export ACCOUNT_EDIT = "/account/edit"
export ACCOUNT = "/account"
export ACCOUNT_ALLOW = "POST, PATCH"
export ACCOUNT_USER = "/account/users/:id"
export ACCOUNT_USER_ALLOW = "POST, PATCH, DELETE"

## The people page, the posts that deactivate and reactivate a person (`:id` is the id of the user), and the post that
## makes a new join code.
export USERS = "/users"
export USER_DEACTIVATE = "/users/:id/deactivate"
export USER_REACTIVATE = "/users/:id/reactivate"
export JOIN_CODE = "/account/join_code"

## The path of the results of a search for `query`, the words that `Searches.words` made.
export def search_path(query: String) -> String
  return "/searches?q=#{URI.encode_www_form_component(query)}"
end

## The path of the room page.
export def room_path(room_id: Int) -> String
  return "/rooms/#{room_id}"
end

## The path of the page of the messages that come before `before` in the room.
export def room_before_path(room_id: Int, before: Int) -> String
  return "/rooms/#{room_id}?before=#{before}"
end

## The path that a message of the room is posted to.
export def room_messages_path(room_id: Int) -> String
  return "/rooms/#{room_id}/messages"
end

## The path of a message, which is where its edit form posts.
export def room_message_path(room_id: Int, message_id: Int) -> String
  return "/rooms/#{room_id}/messages/#{message_id}"
end

## The path of the page that edits a message.
export def room_message_edit_path(room_id: Int, message_id: Int) -> String
  return "/rooms/#{room_id}/messages/#{message_id}/edit"
end

## The path of the settings of an open or closed room, which is also where its form posts.
export def room_settings_path(room_id: Int) -> String
  return "/rooms/#{room_id}/settings"
end

## The path of the sidebar setting of a room, which is also where their form posts.
export def room_involvement_path(room_id: Int) -> String
  return "/rooms/#{room_id}/involvement"
end

## The path of the settings drawn as the form of `kind` (`open` or `closed`), which is how a room is converted: the form
## that is saved says what the room is to be (`SETTINGS_OPEN`, `SETTINGS_CLOSED`).
export def room_settings_kind_path(room_id: Int, kind: String) -> String
  return "/rooms/#{room_id}/settings?type=#{kind}"
end

## The path of the room page around a message.
export def room_at_path(room_id: Int, message_id: Int) -> String
  return "/rooms/#{room_id}/@#{message_id}"
end

## The path of the changes of a room since `millis`.
export def room_refresh_path(room_id: Int, millis: Int) -> String
  return "/rooms/#{room_id}/refresh?since=#{millis}"
end

## The path of the join page of this code, which is also where its form posts.
export def join_path(code: String) -> String
  return "/join/#{code}"
end

## The path of a person under the account, which is where the forms of their role and of their removal post.
export def account_user_path(user_id: Int) -> String
  return "/account/users/#{user_id}"
end

## The path of the page of a user.
export def user_path(user_id: Int) -> String
  return "/users/#{user_id}"
end

## The path of the profile of the person who is signed in, which is also where its form posts.
export def profile_path() -> String
  return "/users/me/profile"
end

## The path that deactivates this user.
export def user_deactivate_path(user_id: Int) -> String
  return "/users/#{user_id}/deactivate"
end

## The path that reactivates this user.
export def user_reactivate_path(user_id: Int) -> String
  return "/users/#{user_id}/reactivate"
end

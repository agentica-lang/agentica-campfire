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
export STYLESHEET = "/assets/campfire-0d54c4f15d2135e3.css"

## The script of the room page (the composer sends with `fetch`), fingerprinted like the stylesheet. Only the room page
## links it; the page works without it.
export COMPOSER_SCRIPT = "/assets/campfire-e3dc16d0562d5461.js"

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

## `/rooms/:id` also takes the form that deletes a room: a `POST` with the field `_method` set to `delete`, as the forms
## of Rails send it (a browser form cannot send `DELETE`), and a real `DELETE`. A `POST` without it, and any other method,
## is a 405 that lists the methods of the path (`ROOM_ALLOW`, which is the list that Bond itself gives for the path).
export ROOM_DELETE_METHOD = "delete"
export ROOM_ALLOW = "GET, HEAD, POST, DELETE"

## The forms of a closed room and of a direct message, and the posts that make them (each makes a room and goes to its
## page), and the settings of a closed room: its form and the post that saves it.
export CLOSED_ROOM_NEW = "/closed_rooms/new"
export CLOSED_ROOMS = "/closed_rooms"
export DIRECT_ROOM_NEW = "/direct_rooms/new"
export DIRECT_ROOMS = "/direct_rooms"
export ROOM_SETTINGS = "/rooms/:id/settings"

## The join link of the account: its page and the post of its form, which is the same path, with the join code as
## `:code`. It is the one page besides the sign-in ones that needs no session (see `AuthWeb.public?`).
export JOIN = "/join/:code"

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

## The path of the settings of a closed room, which is also where its form posts.
export def room_settings_path(room_id: Int) -> String
  return "/rooms/#{room_id}/settings"
end

## The path of the join page of this code, which is also where its form posts.
export def join_path(code: String) -> String
  return "/join/#{code}"
end

## The path that deactivates this user.
export def user_deactivate_path(user_id: Int) -> String
  return "/users/#{user_id}/deactivate"
end

## The path that reactivates this user.
export def user_reactivate_path(user_id: Int) -> String
  return "/users/#{user_id}/reactivate"
end

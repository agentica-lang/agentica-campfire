## The paths of the pages, in one place so that the router, the filter, the redirects and the forms of the views name
## the same ones.

export HOME = "/"
export FIRST_RUN = "/first_run"
export SIGN_IN = "/session/new"
export SESSION = "/session"
export SIGN_OUT = "/sign_out"
export HEALTH = "/health"

## The page that Rails answers at `/up` (the check of its load balancers and of the benchmark harness): green.
export UP = "/up"

## What every 404 of the app says: a path with no route, and a room, a person or a join code that a visitor may not know
## of, so no 404 tells which of them it is.
export MISSING = "Not Found"

## The password reset: the form for the email, the post that asks for the link, the page of the link (with `?token=`)
## and the post that sets the new password.
export PASSWORD_RESET_NEW = "/password_reset/new"
export PASSWORD_RESET = "/password_reset"
export PASSWORD_RESET_EDIT = "/password_reset/edit"
export PASSWORD_RESET_UPDATE = "/password_reset/confirm"

## The rooms: the form of a new one, the post that makes it, a room page (with `?before=ID` for the messages before
## that one) and the post of a message to it. `:id` is the id of the room.
export ROOMS = "/rooms"
export ROOM_NEW = "/rooms/new"
export ROOM = "/rooms/:id"
export ROOM_MESSAGES = "/rooms/:id/messages"

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

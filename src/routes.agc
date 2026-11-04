## The paths of the pages, in one place so that the router, the filter, the redirects and the forms of the views name
## the same ones.

export HOME = "/"
export FIRST_RUN = "/first_run"
export SIGN_IN = "/session/new"
export SESSION = "/session"
export SIGN_OUT = "/sign_out"
export HEALTH = "/health"

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

## Ending the sockets of a person on purpose. A socket is checked once, when it connects and when it subscribes, so
## whatever takes a right away from a person (a sign-out, a deactivation, a password reset, a removal from a closed
## room) has to say so to the hub, which closes their connections with the `disconnect` frame of Action Cable.
##
## `reconnect` is what the client is told. With false it does not come back: right when no session of the person is
## left. With true it reconnects and `/cable` looks the session up again, so the tabs that may still be there are
## welcomed and subscribe again where they are still allowed, and the ones that may not are refused: right when the
## person has another session (a sign-out of one browser), or still has rooms (a removal from one).
##
## This module imports nothing of the app, so the routes of any context can call it.

import Channels from "pkg/channels/channels"

## The `Identity.id` that `/cable` gives to the connections of a person.
export def identity_of(user_id: Int) -> String
  return "#{user_id}"
end

## Ends every connection of the person. A hub that did not take the request is logged: the sockets stay until the next
## check of the session (`CableWeb`), which is the net for this one.
export def user(hub: Channels.Hub, user_id: Int, reconnect: Bool) -> Void
  ended = Channels.disconnect(hub, identity_of(user_id), reconnect)
  if not ended.ok?
    IO.warn("campfire: could not end the sockets of person #{user_id}: #{ended.message}")
  end
end

## Ends the connections of each of the people.
export def users(hub: Channels.Hub, user_ids: List[Int], reconnect: Bool) -> Void
  for user_id in user_ids
    user(hub, user_id, reconnect)
  end
end

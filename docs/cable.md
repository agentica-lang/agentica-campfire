# Live updates over /cable

The app serves the Action Cable WebSocket (`actioncable-v1-json`) at `/cable`, built on the
[`bond-channels`](https://github.com/agentica-lang/packages) package. The Rails clients
(`@rails/actioncable`, `turbo-rails`) and the load generator of the benchmark connect to it unchanged. The pages
listen through their script (see "The pages" below); the HTTP endpoints work as they did, and a `POST` that stores a
message also broadcasts it.

## Connecting

`/cable` is public for the sign-in filter (a 302 on the handshake makes the Rails client retry in a loop). The
connection looks up the session cookie itself and answers a person who is not signed in with
`{"type":"disconnect","reason":"unauthorized","reconnect":false}` and closes. The Origin is checked as Bond does
(the same host, or `CAMPFIRE_BASE_URL` when it is set). A tab that is silent for two minutes is closed; the
server pings the WebSocket and Action Cable every three seconds. A tab too slow to read its frames is dropped
with `disconnect` and `reconnect: true`. `CAMPFIRE_MAX_CONNECTIONS` ([configuration.md](configuration.md))
bounds the tabs.

## Streams

The room page and `GET /users/me/sidebar` carry `<turbo-cable-stream-source channel="X" signed-stream-name="Y">`,
with the markup that the benchmark scrapes. The signed name is the format of Rails (`Turbo.signed_stream_verifier`)
under a key derived from `SECRET_KEY_BASE`, or from `CAMPFIRE_SESSION_SECRET` when that is not set.

| Channel | Stream | Frames |
| --- | --- | --- |
| `RoomMessagesChannel` | the messages of a room (on the room page) | the Turbo Stream that appends a new message. Membership is checked when the subscription is made. |
| `Turbo::StreamsChannel` | `rooms`, and `user:ID:rooms` (on the sidebar) | the Turbo Streams that add a room to the sidebar, or replace its entry when a closed room is renamed. It refuses the names of the message streams. |
| `UnreadRoomsChannel` | `user:ID:unreads` | `{"at":TIME,"roomId":ID}` for each new message of a room that the person has unread or is connected to. |
| `PresenceChannel` | none (params `room_id`) | none. A member's subscription says a tab is looking at the room and marks it read; `refresh` (every 50 s) keeps the person connected for 60 s and checks the session; the end of the subscription removes the tab. A repeat of `present` or `absent` on one connection counts once. A person who is not in the room is rejected. |
| `HeartbeatChannel` | none | none: it confirms, and any action (`check`) looks the session up again. |

## The pages

The script of the pages (`public/assets/campfire-DIGEST.js`, `Routes.SCRIPT`, built from `app/javascript/`) has two parts, `composer.js` and `live.js`. The second opens one
WebSocket in every page that has the sidebar and applies what it hears; no page needs it to work. It is written by
hand, with no Turbo library: it applies `append`, `prepend`, `replace`, `update`, `remove`, `before` and `after`.

- **The signed names** of the sidebar streams come from `GET /users/me/sidebar`, which the script fetches, not from the
  page: the room page is kept whole per person and its markup is the benchmark's. The room page names only its own
  stream.
- **New messages** are appended to the room page when it shows the latest messages (not `?before=`); a message that is
  there already (the sender's tab has the answer of its post) is not added twice, and the answer of the post wins over
  the broadcast, which has no Edit link.
- **After a reconnect**, once the room's subscription is confirmed (what comes later arrives live), the script notes
  the messages of the page, fetches the room page and makes the fetched list the page's: a noted message that the fetch
  lacks is removed (deleted while the socket was away, the newest one and a room that was emptied included; an empty room shows "No messages here yet." again, as it hides it when a message comes), an edited
  one is replaced, and the ones that came are added in order. A noted message older than the fetched ones (the page shows
  the newest 40) stays. A message that a stream brought or touched after the notes is left as the stream made it, because
  the fetch may be older than the stream, and so is the composer. It then fetches `GET /users/me/sidebar` again and takes
  the rooms and the unread marks from it (an unread notice that arrives during that request is lost with the old lists
  until the next notice or load); if the first fetch of the sidebar had given up, this one also subscribes to its streams.
- **The sidebar** (its signed names cost one extra `GET /users/me/sidebar` per page load, a read of the rooms and
  unreads of the person, and another after each reconnect; a failed fetch is tried again up to 8 times with the pause of
  the socket, which doubles up to 30 s) gets the rooms that are made, renamed and deleted, a new one in the order of the
  server (by name, then id). A room that is read shows no mark; an unread one
  is `<li class="unread">` with a hidden "(unread)", set by the server for the rooms with `unread_at` and by the notice
  of `UnreadRoomsChannel` live. The room that a visible tab shows is not marked. The first direct message makes its
  list.
- **Presence**: a room page subscribes to `PresenceChannel` (the room is read), sends `refresh` every 50 s while it is
  visible, `absent` when the tab is hidden and `present` (which reads the room again) when it is shown.
- **A deleted room** replaces the room page of the people looking at it with a notice and the way home, and its entry
  leaves the sidebars of the people who were in it.
- **Every page** sends `HeartbeatChannel` `check` every 50 s, so a socket does not outlive its session.
- A socket that hears no ping for 12 s is closed and opened again; the pause before each try doubles up to 30 s.
- **An edited or deleted message** is replaced or removed on the pages that look at the room. Known limit: the copy
  that replaces it is the one for everyone, without Edit or Delete, so the author's other tabs lose them until the
  page is loaded again.
- Not live yet: the members of a closed room (a person added or taken out) and a room that turns from open to closed
  show in the sidebars at the next load.

## When a right is taken away

A socket is checked when it connects and when it subscribes, so whatever takes a right away ends the sockets of the
person with `Channels.disconnect` (`src/campfire_web/hangup.agc`), which sends `{"type":"disconnect","reason":"remote",
"reconnect":BOOL}` and closes with 1000:

| What happened | `reconnect` | Why |
| --- | --- | --- |
| an administrator deactivates the person | false | no session of theirs is left |
| the person signs out | true | their other sessions are welcomed again at once; the browser that signed out has no cookie and is refused |
| the person is taken out of a closed room (the settings form) | true | the client reconnects and subscribes again; the stream of that room is now rejected. Only the memberships that the update deleted count, read from the database, not from the form |
| the person sets a new password with a reset link | true | the reset ended all their sessions, so the sockets are refused when they come back |
| a check finds the session gone or older than `Auth.SESSION_SECONDS` | true | the same as a sign-out |

The check is `PresenceChannel` `refresh` and `HeartbeatChannel` `check`, which a page sends every 50 s: one read of the
`sessions` table each. If the hub's inbox is full when a hang-up is asked, it is asked again 3 times before it is only logged; the check
above is the net.
A membership that cannot be read (no connection of the pool in time) is tried 3 times; if it still fails, the person's
sockets are told to reconnect and the subscription is rejected, so a burst of reconnects does not leave a member
without their stream for good.

Connected people live in memory (`src/campfire/presence.agc`), not in `memberships.connected_at`. A new message
still sets `unread_at` for everyone in the room but its author (and the people who hid the room), as `Room#receive`
does for people who are not connected in the database, so the page that looks at a room reads it again with
`PresenceChannel`.

## Costs and limits

- A `POST` of a message renders the Turbo Stream once more for the room's stream (the post's own answer is the other
  render), queues the broadcast, and starts a task for the unread notices: one read of the members, a notice for each
  member who has the room unread or is connected, and a `mark_read` write for each person who is looking at the room.
- That task is not bounded: a burst of posts starts that many tasks, each waiting for a connection of the pool. When the
  pool does not answer in time the task ends and the notices of that message are lost without a trace; they are not
  counted in `lost`, which only counts broadcasts that the hub could not queue.
- `mark_read` is a write, so it invalidates the cache of whole pages (`PageCache` keys on the version of the database)
  as any commit does.
- There is no cap of sockets for one person: a person can open as many as `CAMPFIRE_MAX_CONNECTIONS` allows for all.
  That setting defaults to 4096 and is shared with HTTP, since a WebSocket holds a connection of the server for as long
  as its tab is open: a few hundred tabs leave less room for requests.
- The check of the session costs a read every 50 s for each open tab.
- Stopping the app ends the hub first, then waits up to 3 s for the sockets to be told to reconnect (a connection looks
  at the hub every 2 s), and only then stops the server.

`GET /cable/stats` answers the counts of the hub as JSON (`connections`, `subscriptions`, `drops`, `lost`) to an
administrator, and 404 to anyone else. A benchmark run reads there that no tab was dropped for a full inbox
(`drops`) and no broadcast could not be queued (`lost`).

## Acceptance with the benchmark's load generator

`bench/run.sh` does not run the cable profile. By hand, with `loadgen` of
[once-campfire-verification](https://github.com/basecamp/once-campfire-verification) built (`cargo build --release`):

```sh
loadgen login  --base URL --email E --password P            # {"cookie": ...}
loadgen scrape --base URL --cookie C --room 1               # the streams to pass to cable
loadgen cable  --base URL --cookie C --room 1 --clients N --streams 'CH|NAME,...' --refresh-secs 50 --hold-secs 150 | ruby bench/check_sample.rb cable
curl -b C URL/cable/stats                                    # drops and lost must be 0
```

The sample passes when every client is ready (`ready == clients`), none failed, every message is complete and
`drops` and `lost` are 0.

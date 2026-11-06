# Live updates over /cable

The app serves the Action Cable WebSocket (`actioncable-v1-json`) at `/cable`, built on the
[`bond-channels`](https://github.com/agentica-lang/packages) package. The Rails clients
(`@rails/actioncable`, `turbo-rails`) and the load generator of the benchmark connect to it unchanged. The page
does not listen yet; the HTTP endpoints work as they did, and a `POST` that stores a message also broadcasts it.

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
| `PresenceChannel` | none (params `room_id`) | none. A member's subscription says a tab is looking at the room and marks it read; `refresh` (every 50 s) keeps the person connected for 60 s; the end of the subscription removes the tab. A person who is not in the room is rejected. |
| `HeartbeatChannel` | none | none: it only confirms. |

Connected people live in memory (`src/campfire/presence.agc`), not in `memberships.connected_at`. A new message
still sets `unread_at` for everyone in the room but its author (and the people who hid the room), as `Room#receive`
does for people who are not connected in the database, so the page that looks at a room reads it again with
`PresenceChannel`.

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

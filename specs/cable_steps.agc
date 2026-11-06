## The steps of `cable.feature`: WebSocket clients of `/cable`. The peer is `fixtures/cable_peer.py`, a raw-socket
## client that shares no code with the app: it sets the Cookie and the Origin as a browser does and keeps many
## connections open, and a step drives it with one JSON line per command. A client takes the cookies that the browser
## of the scenario has at that moment (`HttpSteps`), so signing in as another person and connecting makes another
## client. A step may halt on what is not the scenario's business (the peer does not answer): that fails the scenario.

import BDD from "std/bdd"
import HttpSteps from "http_steps"

PEER = "cable_peer"
# Relative to the working directory of the run, which is the folder of the repository (`make test`).
PEER_PROGRAM = "specs/fixtures/cable_peer.py"
ANSWER_MS = 15_000
RECEIVE_MS = 5_000
# The most frames that a step skips on the way to the one it waits for (a ping, the confirmations of other streams).
SKIPPED_FRAMES = 200
SUBPROTOCOL = "actioncable-v1-json"
SOURCE_START = "<turbo-cable-stream-source channel=\""
NAME_START = "\" signed-stream-name=\""
NAME_END = "\">"

struct Order
  op: String
  id: String = ""
  path: String = ""
  headers: Map[String, String] = {}
  protocols: String = ""
  text: String = ""
  timeout_ms: Int = 0
end

# A stream that a page names, as the Rails client subscribes to it.
struct Source
  channel: String
  signed: String
end

export def steps() -> List[BDD.Step]
  return [
    BDD.step("the cable peer starts", &peer_starts),
    BDD.step("client {string} connects with the cookies of the browser", &connects),
    BDD.step("the handshake of {string} is answered {int}", &handshake_is),
    BDD.step("client {string} sends:", &sends),
    BDD.step("client {string} subscribes to the channel {string}", &subscribes),
    BDD.step("client {string} subscribes to the channel {string} of the room {int}", &subscribes_in_room),
    BDD.step("client {string} performs {string} in the channel {string} of the room {int}", &performs),
    BDD.step("client {string} subscribes to the streams of the last page", &subscribes_to_page),
    BDD.step("client {string} subscribes to the streams of the remembered page", &subscribes_to_remembered),
    BDD.step(
      "client {string} subscribes to the streams of the last page as the channel {string}",
      &subscribes_to_page_as,
    ),
    BDD.step("client {string} receives:", &receives),
    BDD.step("client {string} eventually receives a frame containing {string}", &eventually_receives),
    BDD.step("client {string} receives nothing for {int} milliseconds", &receives_nothing),
    BDD.step("client {string} is closed by the server with the code {int}", &closed_with),
    BDD.step("client {string} closes", &closes),
  ]
end

def ask(process: Process, request: Json) -> Result[Json]
  try Process.send(process, JSON.encode(request) + "\n", ANSWER_MS)
  line = try Process.read_line(process, ANSWER_MS)
  return JSON.parse(line)
end

def serving(f: Fn[Json, Result[Json]]) -> Fn[Json, Result[Json]]
  return f
end

def peer_starts(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  process = Process.spawn_captured("python3", [PEER_PROGRAM, "#{HttpSteps.port_of(ctx)}"]).unwrap!
  service = serving() do |request| ask(process, request) end
  return BDD.keep(ctx, PEER, service)
end

def peer(ctx: BDD.Context, order: Order) -> Json
  return BDD.call(ctx, PEER, JSON.from(order)).unwrap!
end

def text_of(answer: Json, name: String) -> String
  return JSON.string(JSON.get(answer, name).unwrap_or(JSON.from(""))).unwrap_or("")
end

def int_of(answer: Json, name: String) -> Int
  return JSON.int(JSON.get(answer, name).unwrap_or(JSON.from(0))).unwrap_or(0)
end

def has?(answer: Json, name: String) -> Bool
  return JSON.get(answer, name).ok?
end

# The Origin is the page of the app, as a browser sends it; without cookies there is no Cookie header at all.
def connects(ctx: BDD.Context, args: List[String]) -> BDD.Context
  headers = {"Origin": "http://127.0.0.1:#{HttpSteps.port_of(ctx)}"}
  cookies = HttpSteps.cookie_header(ctx)
  if not cookies.empty?
    headers = headers.put("Cookie", cookies)
  end

  order = Order(op: "connect", id: args[0], path: "/cable", headers: headers, protocols: SUBPROTOCOL)
  answer = peer(ctx, order)
  return BDD.set(ctx, "status #{args[0]}", JSON.get(answer, "status").unwrap!)
end

def handshake_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  status = JSON.int(BDD.get(ctx, "status #{args[0]}").unwrap!).unwrap!
  return BDD.assert(ctx, status == args[1].to_i!, "the handshake of #{args[0]} was answered #{status}")
end

def send_text(ctx: BDD.Context, id: String, text: String) -> BDD.Context
  _ = peer(ctx, Order(op: "send", id: id, text: text))
  return ctx
end

def sends(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return send_text(ctx, args[0], BDD.doc_string(ctx))
end

def subscribe_command(identifier: String) -> String
  return JSON.encode({"command": "subscribe", "identifier": identifier})
end

def subscribes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return send_text(ctx, args[0], subscribe_command(JSON.encode({"channel": args[1]})))
end

def room_identifier(channel: String, room_id: Int) -> String
  return JSON.encode({"channel": JSON.from(channel), "room_id": JSON.from(room_id)})
end

def subscribes_in_room(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return send_text(ctx, args[0], subscribe_command(room_identifier(args[1], args[2].to_i!)))
end

def performs(ctx: BDD.Context, args: List[String]) -> BDD.Context
  command = JSON.encode({
    "command": JSON.from("message"),
    "identifier": JSON.from(room_identifier(args[2], args[3].to_i!)),
    "data": JSON.from(JSON.encode({"action": args[1]})),
  })

  return send_text(ctx, args[0], command)
end

# The streams that a page names with `<turbo-cable-stream-source channel="X" signed-stream-name="Y">`, which the
# benchmark scrapes in the same way.
def sources_of(body: String) -> List[Source]
  found: List[Source] = []
  for part in body.split(SOURCE_START).drop(1)
    channel_end = part.index_of(NAME_START).unwrap_or(-1)
    if channel_end < 0
      next
    end

    rest = part.slice(channel_end + NAME_START.length, part.length - channel_end - NAME_START.length)
    name_end = rest.index_of(NAME_END).unwrap_or(-1)
    if name_end < 0
      next
    end

    found = found.push(Source(channel: part.slice(0, channel_end), signed: rest.slice(0, name_end)))
  end

  return found
end

def subscribe_sources(ctx: BDD.Context, id: String, body: String, channel: String) -> BDD.Context
  found = sources_of(body)
  result = BDD.assert(ctx, not found.empty?, "the page names no stream: #{body}")
  for source in found
    named = source.channel
    if not channel.empty?
      named = channel
    end

    identifier = JSON.encode({"channel": named, "signed_stream_name": source.signed})
    result = send_text(result, id, subscribe_command(identifier))
  end

  return result
end

def subscribes_to_page(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return subscribe_sources(ctx, args[0], HttpSteps.last_body(ctx), "")
end

def subscribes_to_remembered(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return subscribe_sources(ctx, args[0], HttpSteps.remembered_body(ctx), "")
end

def subscribes_to_page_as(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return subscribe_sources(ctx, args[0], HttpSteps.last_body(ctx), args[1])
end

def next_frame(ctx: BDD.Context, id: String, timeout_ms: Int) -> Json
  return peer(ctx, Order(op: "recv", id: id, timeout_ms: timeout_ms))
end

def receives(ctx: BDD.Context, args: List[String]) -> BDD.Context
  frame = next_frame(ctx, args[0], RECEIVE_MS)
  expected = BDD.doc_string(ctx)
  return BDD.assert(ctx, text_of(frame, "text") == expected, "#{args[0]} got #{frame}, expected #{expected}")
end

# Skips what comes before (the confirmations, a ping): a scenario states what it must hear.
def eventually_receives(ctx: BDD.Context, args: List[String]) -> BDD.Context
  for _skipped in 1..SKIPPED_FRAMES
    frame = next_frame(ctx, args[0], RECEIVE_MS)
    if text_of(frame, "text").include?(args[1])
      return BDD.assert(ctx, true, "")
    end

    if not has?(frame, "text")
      return BDD.assert(ctx, false, "#{args[0]} got #{frame} before a frame with #{args[1]}")
    end
  end

  return BDD.assert(ctx, false, "#{args[0]} heard no frame with #{args[1]} in #{SKIPPED_FRAMES} frames")
end

def receives_nothing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  frame = next_frame(ctx, args[0], args[1].to_i!)
  return BDD.assert(ctx, has?(frame, "timeout"), "#{args[0]} got #{frame}, expected nothing")
end

def closed_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  for _skipped in 1..SKIPPED_FRAMES
    frame = next_frame(ctx, args[0], RECEIVE_MS)
    if not has?(frame, "text")
      code = int_of(frame, "closed")
      return BDD.assert(ctx, code == args[1].to_i!, "#{args[0]} was closed with #{code} (#{frame})")
    end
  end

  return BDD.assert(ctx, false, "#{args[0]} was not closed")
end

def closes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  _ = peer(ctx, Order(op: "close", id: args[0]))
  return ctx
end

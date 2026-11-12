## The WebSocket clients of `cable.feature`: the independent peer of the cable server. It is the package
## `websocket-client`, which shares no code with the server (Bond over `std/http`), so a scenario can set the Cookie,
## the Origin and the subprotocol and keep many connections open at once.
##
## It has a manifest of its own (this folder), so that the app does not depend on the client: a manifest has one
## list of dependencies, and a user of the app would fetch it. It is a program of its own because a step cannot leave a task running (`RUNTIME-BDD-PENDING-TASKS`), and the reader
## of a connection must: a task per connection reads it into a channel and answers the pings, as a browser does, so
## that a command can wait for a frame with a timeout without closing the connection.
##
## Usage: cable_client.agc PORT. It reads one JSON command per line on stdin and answers one JSON line each:
##   connect id path [headers] [protocols] -> {status}      send id text -> {}
##   recv id timeout_ms -> {text} | {closed: code} | {timeout: true}
##   close id (a close frame) | drop id (no close frame)

import WebSocket from "pkg/websocket-client/websocket"

# One day: a reader never times out by itself, `recv` has its own timeout.
FOREVER_MS = 86_400_000
# The frames that a connection may hold unread: a burst of a scenario fits.
INBOX_FRAMES = 4096
# The close handshake takes no time: the reader task would take the answer of the server.
CLOSE_MS = 1
SEND_MS = 5_000

struct Order
  op: String
  id: String = ""
  path: String = ""
  headers: Map[String, String] = {}
  protocols: String = ""
  text: String = ""
  timeout_ms: Int = 0
end

# A connection and the frames that its reader has read.
struct Line
  ws: WebSocket.Client
  inbox: Channel[WebSocket.Message]
end

# What a command gives: its answer, and the connections after it.
struct Pair
  answer: Json
  lines: Map[String, Line]
end

# The task that reads a connection: every message goes to the inbox (`receive` answers a ping), and the end of the
# connection, with a close frame or not, is the last one.
def pump(line: Line) -> Void
  while true
    case WebSocket.receive(line.ws)
      ok(message) ->
        _ = line.inbox.send(message, SEND_MS)
        case message
          WebSocket.Message.Close(_, _) -> break
          WebSocket.Message.Text(_) -> nil
          WebSocket.Message.Binary(_) -> nil
        end

      error(_) ->
        _ = line.inbox.send(WebSocket.Message.Close(1006, ""), SEND_MS)
        break
    end
  end

  line.inbox.close
end

def nothing() -> Json = JSON.parse("{}").unwrap!

def failed(reason: String) -> Json = JSON.from({"error": JSON.from(reason)})

def options_of(order: Order) -> WebSocket.Options
  headers = order.headers.keys.map do |name| Header(name: name, value: order.headers[name]) end
  protocols = order.protocols.split(",").map do |name| name.strip end.select do |name| not name.empty? end
  WebSocket.Options(headers: headers, protocols: protocols, read_timeout_ms: FOREVER_MS, close_timeout_ms: CLOSE_MS)
end

# The answer of a handshake: `Open` keeps the connection and starts its reader; a refusal has the status alone.
def connect(port: Int, order: Order, lines: Map[String, Line]) -> Pair
  case WebSocket.handshake("ws://127.0.0.1:#{port}#{order.path}", options_of(order))
    error(reason) -> Pair(answer: failed(reason), lines: lines)

    ok(answer) ->
      case answer
        WebSocket.Handshake.Refused(status, _, _) ->
          Pair(answer: JSON.from({"status": JSON.from(status)}), lines: lines)

        WebSocket.Handshake.Open(ws) ->
          inbox: Channel[WebSocket.Message] = Channel.new(INBOX_FRAMES)
          line = Line(ws: ws, inbox: inbox)
          _ = Task.spawn(&pump, line)
          Pair(answer: JSON.from({"status": JSON.from(ws.status)}), lines: lines.put(order.id, line))
      end
  end
end

def frame_json(message: WebSocket.Message) -> Json
  case message
    WebSocket.Message.Text(text) -> JSON.from({"text": JSON.from(text)})
    WebSocket.Message.Binary(_) -> JSON.from({"binary": JSON.from(true)})
    WebSocket.Message.Close(code, _) -> JSON.from({"closed": JSON.from(code)})
  end
end

def receive(line: Line, timeout_ms: Int) -> Json
  case line.inbox.recv(timeout_ms)
    ok(message) -> frame_json(message)
    error(_) -> JSON.from({"timeout": JSON.from(true)})
  end
end

def on_line(line: Line, order: Order) -> Json
  case order.op
    "send" ->
      case WebSocket.send_text(line.ws, order.text)
        ok(_) -> nothing()
        error(reason) -> failed(reason)
      end

    "recv" -> receive(line, order.timeout_ms)

    "close" ->
      _ = WebSocket.close(line.ws, 1000, "")
      nothing()

    "drop" ->
      TCP.close(line.ws.socket)
      nothing()

    _ -> failed("unknown operation #{order.op}")
  end
end

def run(port: Int, order: Order, lines: Map[String, Line]) -> Pair
  return connect(port, order, lines) if order.op == "connect"

  case lines.get(order.id)
    some(line) -> Pair(answer: on_line(line, order), lines: lines)
    none -> Pair(answer: failed("no connection #{order.id}"), lines: lines)
  end
end

def decode(text: String) -> Result[Order]
  json = try JSON.parse(text)
  JSON.decode(json, Order)
end

def main() -> Void
  port = System.args()[0].to_i!
  lines: Map[String, Line] = {}
  while true
    case IO.gets()
      error(_) -> break
      ok(text) ->
        case decode(text)
          error(reason) -> puts(JSON.encode(failed(reason)))
          ok(order) ->
            done = run(port, order, lines)
            lines = done.lines
            puts(JSON.encode(done.answer))
        end

        IO.flush()
    end
  end
end

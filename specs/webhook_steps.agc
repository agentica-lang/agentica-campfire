## The steps of the webhooks of the bots. The webhook is `fixtures/webhook_peer.py` (Python's standard library, an
## implementation of HTTP apart from the app's), a child process that a service keeps; it writes one JSON line for each
## post it gets, which the steps read.

import BDD from "std/bdd"

## The steps of the webhook peer.
def steps() -> List[BDD.Step]
  [
    BDD.step("the webhook answers {string} as {string}", &peer_answers),
    BDD.step("the webhook answers after {int} milliseconds", &peer_waits),
    BDD.step("the webhook answers after {int} milliseconds only on {string}", &peer_waits_on),
    BDD.step("the webhook is listening", &peer_listens),
    BDD.step("the webhook receives a post", &peer_received),
    BDD.step("the post contains {string}", &post_contains),
    BDD.step("the webhook receives nothing within {int} milliseconds", &peer_received_nothing),
  ]
end

## The URL of the peer with this path, for the SQL of a step.
def url(ctx: BDD.Context, path: String) -> String
  "http://127.0.0.1:#{JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!}#{path}"
end

private

PEER = "specs/fixtures/webhook_peer.py"
SERVICE = "webhook_peer"
PORT = "webhook_port"
REPLY = "webhook_reply"
KIND = "webhook_type"
DELAY = "webhook_delay"
SLOW_PATH = "webhook_slow_path"
POST = "webhook_post"
LISTENING = "listening "
STARTUP_MS = 10_000
# A post comes from a task of the app after the request has been answered, so the wait is generous.
POST_MS = 10_000

def text_of(ctx: BDD.Context, name: String) -> String
  case BDD.get(ctx, name)
    ok(value) -> JSON.string(value).unwrap_or("")
    error(_) -> ""
  end
end

def peer_answers(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(BDD.set(ctx, REPLY, JSON.from(args[0])), KIND, JSON.from(args[1]))
end

def peer_waits(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.set(ctx, DELAY, JSON.from(args[0]))

def peer_waits_on(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(BDD.set(ctx, DELAY, JSON.from(args[0])), SLOW_PATH, JSON.from(args[1]))
end

def peer_listens(ctx: BDD.Context, args: List[String]) -> BDD.Context
  env = {
    "WEBHOOK_PEER_REPLY": text_of(ctx, REPLY),
    "WEBHOOK_PEER_TYPE": text_of(ctx, KIND),
    "WEBHOOK_PEER_DELAY_MS": text_of(ctx, DELAY),
    "WEBHOOK_PEER_SLOW_PATH": text_of(ctx, SLOW_PATH),
  }

  started = Process.spawn_captured("python3", [PEER], Process.Options(env: env.select { |_, v| not v.empty? }))
  return BDD.assert(ctx, false, "cannot start the webhook: #{started.message}") if not started.ok?

  peer = started.unwrap!
  line = Process.read_line(peer, STARTUP_MS)
  if not line.ok? or not line.unwrap!.start_with?(LISTENING)
    return BDD.assert(ctx, false, "the webhook did not start: #{line.message}")
  end

  port = line.unwrap!.slice(LISTENING.length, line.unwrap!.length - LISTENING.length).to_i!
  kept = BDD.keep(ctx, SERVICE) do |request| next_post(peer, request) end
  BDD.set(kept, PORT, JSON.from(port))
end

# The next line of the peer within the milliseconds of the request, or "" when none comes.
def next_post(peer: Process, request: JSON.Value) -> Result[JSON.Value]
  wait_ms = try JSON.int(request)
  line = Process.read_line(peer, wait_ms)
  return ok(JSON.from("")) if not line.ok?

  ok(JSON.from(line.unwrap!))
end

def peer_received(ctx: BDD.Context, args: List[String]) -> BDD.Context
  said = BDD.call(ctx, SERVICE, JSON.from(POST_MS))
  return BDD.assert(ctx, false, "cannot read the webhook: #{said.message}") if not said.ok?

  line = JSON.string(said.unwrap!).unwrap_or("")
  return BDD.assert(ctx, false, "the webhook got no post") if line.empty?

  BDD.assert(BDD.set(ctx, POST, JSON.from(line)), true, "")
end

def post_contains(ctx: BDD.Context, args: List[String]) -> BDD.Context
  line = text_of(ctx, POST)
  BDD.assert(ctx, line.include?(args[0]), "the post is #{line}")
end

def peer_received_nothing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  said = BDD.call(ctx, SERVICE, JSON.from(args[0].to_i!))
  return BDD.assert(ctx, false, "cannot read the webhook: #{said.message}") if not said.ok?

  line = JSON.string(said.unwrap!).unwrap_or("")
  BDD.assert(ctx, line.empty?, "the webhook got #{line}")
end

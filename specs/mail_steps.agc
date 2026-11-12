## The steps for the email of the app. The app is the one program of a scenario, so the mail server (the SMTP peer of
## `fixtures/smtp_peer.agc`, which writes down the dialogue) runs as a child process that a service keeps, and the
## steps read what it saw. A message comes in the transcript as the client sent it, quoted-printable when a line is
## long, so the steps decode it before they look for the link of a reset.

import BDD from "std/bdd"
import URI from "std/uri"
import HttpSteps from "http_steps"

PORT = "mail_port"
AUTH = "mail_auth"
STALL = "mail_stall"
REFUSED = "mail_refused"
ADDRESS = "mail_address"
QUEUE = "mail_queue"
USER = "mail_user"
PASSWORD = "mail_password"
SERVICE = "mail"
MESSAGE = "mail_message"
LINK = "mail_link"
ENABLED = "mail_enabled"

## The public address that the app is given, so that the links in its emails do not depend on the port it listens on.
export BASE_URL = "https://campfire.test"

LISTENING = "listening on "
CLOSED = "closed"
CLOSED_PORT = 1
STARTUP_MS = 10_000
LINK_PREFIX = "#{BASE_URL}/password_reset/edit?token="
BODY_START = "C: DATA"
BODY_END = "C: ."
CLIENT = "C: "
SOFT_BREAK = "="
HEX_DIGITS = "0123456789ABCDEF"
PEER = "specs/fixtures/smtp_peer.agc"

# Connections that the mail server takes one after the other: a message sent twice shows as two of them.
PEER_CONNECTIONS = 4
COUNT_SEGMENTS_MS = 700
UPDATE_PATH = "/password_reset/confirm"

struct Transcript
  lines: List[String]
  ended: Bool
end

# What a service call asks of the peer: lines up to `closed`, or, when `until` is not empty, up to the first line that
# starts with it.
struct Request
  wait_ms: Int
  until: String
end

## The steps of the mail server and of the links that it receives.
export def steps() -> List[BDD.Step]
  [
    BDD.step("the mail server offers AUTH {string}", &server_offers_auth),
    BDD.step("the mail server never answers {string}", &server_never_answers),
    BDD.step("the mail server refuses the recipient {string}", &server_refuses_recipient),
    BDD.step("the app is given the public address {string}", &app_has_address),
    BDD.step("the mail server is listening", &server_listens),
    BDD.step("the app sends its email through the mail server", &app_uses_server),
    BDD.step("the app sends its email to a port where no mail server listens", &app_uses_closed_port),
    BDD.step("the app logs in to the mail server as {string} with the password {string}", &app_logs_in),
    BDD.step("the mail server heard {string}", &server_heard),
    BDD.step("the mail server received a message to {string} with the subject {string}", &server_received),
    BDD.step("the mail server received nothing within {int} milliseconds", &server_received_nothing),
    BDD.step("the mail server got {int} messages in all", &server_got_messages),
    BDD.step("the app queues at most {int} messages for the mail server", &app_queues),
    BDD.step("I open the link of the email", &open_link),
    BDD.step("I set the password {string} with the token of the link", &set_password_with_link),
    BDD.step("I set the password {string} with the token of the link {int} times at once", &set_password_at_once),
    BDD.step("I set the password {string} with the token {string}", &set_password),
  ]
end

## The environment that the app starts with for its email: the url of the mail server when a scenario has one (and the
## public address that goes with it), else nothing (but the public address, when a scenario gives one), so that the
## environment of whoever runs the specs does not leak.
export def app_environment(ctx: BDD.Context) -> Map[String, String]
  if not BDD.get(ctx, PORT).ok? or not flag(ctx, ENABLED)
    # A public address does not need a mail server: the join link starts with it too.
    return {"CAMPFIRE_SMTP_URL": "", "CAMPFIRE_BASE_URL": text_of(ctx, ADDRESS), "CAMPFIRE_MAIL_QUEUE_SIZE": ""}
  end

  login = ""
  if not text_of(ctx, USER).empty?
    login = "#{URI.encode_uri_component(text_of(ctx, USER))}:#{URI.encode_uri_component(text_of(ctx, PASSWORD))}@"
  end

  url = "smtp+plain://#{login}127.0.0.1:#{JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!}"
  address = text_of(ctx, ADDRESS)
  if address.empty?
    address = BASE_URL
  end

  queue = text_of(ctx, QUEUE)
  {"CAMPFIRE_SMTP_URL": url, "CAMPFIRE_BASE_URL": address, "CAMPFIRE_MAIL_QUEUE_SIZE": queue}
end

## The token in the link of the last email that a step opened.
export def link_token(ctx: BDD.Context) -> String = text_of(ctx, LINK)

def server_offers_auth(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.set(ctx, AUTH, JSON.from(args[0]))

def app_queues(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.set(ctx, QUEUE, JSON.from(args[0]))

def server_never_answers(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.set(ctx, STALL, JSON.from(args[0]))

def server_refuses_recipient(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, REFUSED, JSON.from(args[0]))
end

def app_has_address(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.set(ctx, ADDRESS, JSON.from(args[0]))

def app_uses_server(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.set(ctx, ENABLED, JSON.from(true))

# Port 1 is never open on a machine that runs the specs, and a connection to it is refused at once.
def app_uses_closed_port(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(BDD.set(ctx, ENABLED, JSON.from(true)), PORT, JSON.from(CLOSED_PORT))
end

def app_logs_in(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(BDD.set(ctx, USER, JSON.from(args[0])), PASSWORD, JSON.from(args[1]))
end

# The peer serves `PEER_CONNECTIONS` connections one after the other, so a scenario can send a few emails (the mailer
# opens one connection per message). A process belongs to the task that opened it, which is the scenario, so the
# service block that reads it is the one place that touches it.
def server_listens(ctx: BDD.Context, args: List[String]) -> BDD.Context
  root = Path.cwd().unwrap!
  env = {
    "SMTP_PEER_MODE": "plain",
    "SMTP_PEER_AUTH": text_of(ctx, AUTH),
    "SMTP_PEER_STALL": text_of(ctx, STALL),
    "SMTP_PEER_REJECT_RCPT": text_of(ctx, REFUSED),
    "SMTP_PEER_CONNECTIONS": "#{PEER_CONNECTIONS}",
  }

  started = Process.spawn_captured("agentica", [Path.join([root, PEER]).unwrap!], Process.Options(env: env))
  return BDD.assert(ctx, false, "cannot start the mail server: #{started.message}") if not started.ok?

  peer = started.unwrap!
  line = Process.read_line(peer, STARTUP_MS)
  if not line.ok? or not line.unwrap!.start_with?(LISTENING)
    return BDD.assert(ctx, false, "the mail server did not start: #{line.message}")
  end

  port = line.unwrap!.slice(LISTENING.length, line.unwrap!.length - LISTENING.length).to_i!
  kept = BDD.keep(ctx, SERVICE) do |request| answer(peer, request) end
  BDD.set(kept, PORT, JSON.from(port))
end

def answer(peer: Process, request: Json) -> Result[Json]
  asked = try JSON.decode(request, Request)
  ok(JSON.from(read_transcript(peer, asked)))
end

# The lines of the dialogue up to `closed`, which the peer says once the client has hung up, or up to the line that
# `until` names.
def read_transcript(peer: Process, asked: Request) -> Transcript
  lines: List[String] = []
  for _ in 0...1000
    line = Process.read_line(peer, asked.wait_ms)
    return Transcript(lines: lines, ended: false) if not line.ok?

    return Transcript(lines: lines, ended: true) if line.unwrap! == CLOSED

    lines = lines.push(line.unwrap!)
    return Transcript(lines: lines, ended: false) if not asked.until.empty? and line.unwrap!.start_with?(asked.until)
  end

  Transcript(lines: lines, ended: false)
end

def transcript_of(ctx: BDD.Context, wait_ms: Int, until: String = "") -> Result[Transcript]
  said = try BDD.call(ctx, SERVICE, JSON.from(Request(wait_ms: wait_ms, until: until)))
  JSON.decode(said, Transcript)
end

# A state that a scenario can wait for instead of a time: the app has connected and said this command. The lines up to
# it are read, so a later step of the transcript starts after it.
def server_heard(ctx: BDD.Context, args: List[String]) -> BDD.Context
  prefix = "#{CLIENT}#{args[0]}"
  read = transcript_of(ctx, STARTUP_MS, prefix)
  return BDD.assert(ctx, false, "cannot read the mail server: #{read.message}") if not read.ok?

  lines = read.unwrap!.lines
  found = lines.any? do |line| line.start_with?(prefix) end
  BDD.assert(ctx, found, "the mail server saw:\n#{lines.join("\n")}")
end

# A message that the app sends takes a moment (the sending is off the request), so the wait is generous.
def server_received(ctx: BDD.Context, args: List[String]) -> BDD.Context
  read = transcript_of(ctx, STARTUP_MS)
  return BDD.assert(ctx, false, "cannot read the mail server: #{read.message}") if not read.ok?

  lines = read.unwrap!.lines
  subject = "C: Subject: #{args[1]}"
  found = lines.include?("C: RCPT TO:<#{args[0]}>") and lines.include?(subject)
  BDD.assert(
    BDD.set(ctx, MESSAGE, JSON.from(body_of(lines).join("\n"))),
    found,
    "the mail server saw:\n#{lines.join("\n")}",
  )
end

# Reads the connections one after the other, as long as the next one comes, and counts the ones that carried a message.
# A wait that ends with nothing stops the server process, so this is the last use of it.
def server_got_messages(ctx: BDD.Context, args: List[String]) -> BDD.Context
  sent = 0
  wait_ms = STARTUP_MS
  for _ in 0...PEER_CONNECTIONS
    read = transcript_of(ctx, wait_ms)
    break if not read.ok? or read.unwrap!.lines.empty?

    if read.unwrap!.lines.include?("C: DATA")
      sent += 1
    end

    wait_ms = COUNT_SEGMENTS_MS
  end

  BDD.assert(ctx, sent == args[0].to_i!, "the mail server got #{sent} messages, not #{args[0]}")
end

def server_received_nothing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  read = transcript_of(ctx, args[0].to_i!)
  return BDD.assert(ctx, false, "cannot read the mail server: #{read.message}") if not read.ok?

  lines = read.unwrap!.lines
  BDD.assert(ctx, not lines.any? do |line| line.start_with?("C: MAIL FROM") end, "the server saw:\n#{lines}")
end

# What the client sent between DATA and the final dot, decoded from quoted-printable (a line that ends with `=` goes on
# in the next one, and `=3D` is `=`).
def body_of(lines: List[String]) -> List[String]
  said = lines.select do |line| line.start_with?(CLIENT) end
  sent = said.map do |line| line.slice(CLIENT.length, line.length - CLIENT.length) end
  after_data = sent.drop_while do |line| line != "DATA" end
  inside = after_data.drop(1).take_while do |line| line != "." end
  unfold(inside).map do |line| unescape(line) end
end

def unfold(lines: List[String]) -> List[String]
  joined: List[String] = []
  pending = ""
  for line in lines
    if line.end_with?(SOFT_BREAK)
      pending = "#{pending}#{line.slice(0, line.length - 1)}"
    else
      joined = joined.push("#{pending}#{line}")
      pending = ""
    end
  end

  joined
end

# `=XX` is the character with that code, for the ASCII that a link is made of.
def unescape(line: String) -> String
  chars = line.split("")
  out: List[String] = []
  index = 0
  while index < chars.size
    if chars[index] == SOFT_BREAK and index + 2 < chars.size and hex_value(chars[index + 1], chars[index + 2]) >= 0
      out = out.push(String.from_code(hex_value(chars[index + 1], chars[index + 2])))
      index += 3
    else
      out = out.push(chars[index])
      index += 1
    end
  end

  out.join("")
end

def hex_value(high: String, low: String) -> Int
  first = HEX_DIGITS.index_of(high.upcase).unwrap_or(-1)
  second = HEX_DIGITS.index_of(low.upcase).unwrap_or(-1)
  return -1 if first < 0 or second < 0 or high.length != 1 or low.length != 1

  first * 16 + second
end

def open_link(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = text_of(ctx, MESSAGE).split("\n")
  found = lines.find do |line| line.start_with?(LINK_PREFIX) end
  if not found.ok?
    return BDD.assert(ctx, false, "the email has no link that starts with #{LINK_PREFIX}:\n#{lines.join("\n")}")
  end

  link = found.unwrap!.strip
  token = link.slice(LINK_PREFIX.length, link.length - LINK_PREFIX.length)
  kept = BDD.set(ctx, LINK, JSON.from(token))
  HttpSteps.get(kept, [link.slice(BASE_URL.length, link.length - BASE_URL.length)])
end

def set_password_with_link(ctx: BDD.Context, args: List[String]) -> BDD.Context
  submit(ctx, args[0], text_of(ctx, LINK))
end

def set_password_at_once(ctx: BDD.Context, args: List[String]) -> BDD.Context
  HttpSteps.post_at_once(ctx, UPDATE_PATH, form_of(args[0], text_of(ctx, LINK)), args[1].to_i!)
end

def set_password(ctx: BDD.Context, args: List[String]) -> BDD.Context = submit(ctx, args[0], args[1])

def submit(ctx: BDD.Context, password: String, token: String) -> BDD.Context
  HttpSteps.post(ctx, UPDATE_PATH, form_of(password, token))
end

def form_of(password: String, token: String) -> String
  URI.encode_www_form([URI.Pair(name: "token", value: token), URI.Pair(name: "password", value: password)])
end

def text_of(ctx: BDD.Context, name: String) -> String
  value = BDD.get(ctx, name)
  return "" if not value.ok?

  JSON.string(value.unwrap!).unwrap_or("")
end

def flag(ctx: BDD.Context, name: String) -> Bool
  value = BDD.get(ctx, name)
  return false if not value.ok?

  JSON.bool(value.unwrap!).unwrap_or(false)
end

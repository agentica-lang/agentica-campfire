## The steps of `smtp.feature`: the SMTP peer of `fixtures/smtp_peer.agc` is the program under test, and the client of
## `src/smtp.agc` runs in the step itself, against the port that the peer reports. The peer writes the dialogue to its
## stdout, and the steps read it once the connection has ended, so every assertion about what the server saw is an
## assertion about its transcript.

import BDD from "std/bdd"
import Smtp from "../src/smtp"

PORT = "smtp_port"
SECURITY = "smtp_security"
USERNAME = "smtp_username"
PASSWORD = "smtp_password"
HOST = "smtp_host"
TIMEOUT = "smtp_timeout_ms"
STAMP = "smtp_stamp"
OUTCOME = "smtp_outcome"
TRANSCRIPT = "smtp_transcript"
ENDED = "smtp_ended"
SYSTEM_TRUST = "smtp_system_trust"

LISTENING = "listening on "
CLOSED = "closed"
STARTUP_MS = 5_000
TRANSCRIPT_MS = 5_000
DEFAULT_TIMEOUT_MS = 5_000
CERTS_FOLDER = "specs/fixtures/tls"
FIXED_DATE = "Tue, 03 Nov 2026 10:55:02 +0000"
FIXED_ID = "<spec@example.com>"

struct Transcript
  lines: List[String]
  ended: Bool
end

## The steps of the SMTP features.
export def steps() -> List[BDD.Step]
  return [
    BDD.step("the SMTP server speaks {string}", &server_speaks),
    BDD.step("the SMTP server offers AUTH {string}", &server_offers_auth),
    BDD.step("the SMTP server refuses the recipient {string}", &server_refuses_recipient),
    BDD.step("the SMTP server never answers {string}", &server_never_answers),
    BDD.step("the SMTP server answers {string} with {string}", &server_answers),
    BDD.step("the SMTP server pauses {int} milliseconds between the lines of a reply", &server_pauses),
    BDD.step("the SMTP server uses the certificate {string}", &server_certificate),
    BDD.step("the SMTP server is listening", &server_listens),
    BDD.step("the client uses {string} security", &client_security),
    BDD.step("the client trusts only the system certificates", &client_system_trust),
    BDD.step("the client logs in as {string} with the password {string}", &client_logs_in),
    BDD.step("the client waits {int} milliseconds for each reply", &client_waits),
    BDD.step("the client connects to the host {string}", &client_host),
    BDD.step("the client makes the date and the message id itself", &client_stamps),
    BDD.step("I send a message from {string} to {string} with the subject {string} and the text:", &send_text),
    BDD.step(
      "I send a message from {string} to {string} with the subject {string}, the text {string} and the html {string}",
      &send_multipart,
    ),
    BDD.step("I send two messages on one connection", &send_two),
    BDD.step("I send a message over a connection that I open, upgrade and log in step by step", &send_by_steps),
    BDD.step(
      "I connect, find that the client no longer holds the password, and send a message",
      &send_without_password,
    ),
    BDD.step("the send succeeds", &send_succeeds),
    BDD.step("the send fails with the code {int}", &send_fails_with_code),
    BDD.step("the send fails without a code", &send_fails_without_code),
    BDD.step("the error mentions {string}", &error_mentions),
    BDD.step("the error does not mention {string}", &error_does_not_mention),
    BDD.step("the server saw the connection close", &connection_closed),
    BDD.step("the server transcript is:", &transcript_is),
    BDD.step("the server transcript has the line {string}", &transcript_has_line),
    BDD.step("the server transcript has a line starting with {string}", &transcript_has_prefix),
    BDD.step("the server transcript has no line starting with {string}", &transcript_lacks_prefix),
    BDD.step("the server transcript has {int} lines starting with {string}", &transcript_counts_prefix),
  ]
end

def server_speaks(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_env(ctx, "SMTP_PEER_MODE", args[0])
end

def server_offers_auth(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_env(ctx, "SMTP_PEER_AUTH", args[0])
end

def server_refuses_recipient(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_env(ctx, "SMTP_PEER_REJECT_RCPT", args[0])
end

def server_never_answers(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_env(ctx, "SMTP_PEER_STALL", args[0])
end

def server_answers(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_env(BDD.given_env(ctx, "SMTP_PEER_CANNED_VERB", args[0]), "SMTP_PEER_CANNED", args[1])
end

def server_pauses(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_env(ctx, "SMTP_PEER_LINE_DELAY_MS", args[0])
end

def server_certificate(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_env(ctx, "SMTP_PEER_CERT", args[0])
end

def client_system_trust(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, SYSTEM_TRUST, JSON.from(true))
end

# The certificates are in the repository, found from the folder that `agentica test` runs in (the root of the app).
def certs_dir() -> String
  return Path.join([Path.cwd().unwrap!, CERTS_FOLDER]).unwrap!
end

def server_listens(ctx: BDD.Context, args: List[String]) -> BDD.Context
  configured = BDD.given_env(ctx, "SMTP_PEER_CERTS", certs_dir())
  started = BDD.given_program(configured, "fixtures/smtp_peer.agc")
  line = BDD.read_line(started, STARTUP_MS)
  if not line.ok? or not line.unwrap!.start_with?(LISTENING)
    return BDD.assert(started, false, "the SMTP peer did not start: #{line.message}")
  end

  port = line.unwrap!.slice(LISTENING.length, line.unwrap!.length - LISTENING.length).to_i!
  return BDD.set(started, PORT, JSON.from(port))
end

def client_security(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, SECURITY, JSON.from(args[0]))
end

def client_logs_in(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(BDD.set(ctx, USERNAME, JSON.from(args[0])), PASSWORD, JSON.from(args[1]))
end

def client_waits(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, TIMEOUT, JSON.from(args[0].to_i!))
end

def client_host(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, HOST, JSON.from(args[0]))
end

def client_stamps(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, STAMP, JSON.from(true))
end

def send_text(ctx: BDD.Context, args: List[String]) -> BDD.Context
  message = message_of(ctx, args[0], args[1], args[2], BDD.doc_string(ctx), "")
  return finish(ctx, Smtp.send(message, options_of(ctx)))
end

def send_multipart(ctx: BDD.Context, args: List[String]) -> BDD.Context
  message = message_of(ctx, args[0], args[1], args[2], args[3], args[4])
  return finish(ctx, Smtp.send(message, options_of(ctx)))
end

# The client that keeps the connection: two messages, one EHLO, one QUIT.
def send_two(ctx: BDD.Context, args: List[String]) -> BDD.Context
  first = message_of(ctx, "ana@example.com", "bob@example.com", "First", "one", "")
  second = message_of(ctx, "ana@example.com", "cy@example.com", "Second", "two", "")
  return finish(ctx, session(options_of(ctx), first, second))
end

def send_by_steps(ctx: BDD.Context, args: List[String]) -> BDD.Context
  message = message_of(ctx, "ana@example.com", "bob@example.com", "Steps", "by hand", "")
  return finish(ctx, by_steps(options_of(ctx), message))
end

# What `connect` does, with the public steps: the encrypted client of `starttls` is the one to go on with.
def by_steps(options: Smtp.Options, message: Smtp.Message) -> Result[Void]
  opened = try Smtp.open(options)
  said = Smtp.ehlo(opened)
  if not said.ok?
    Smtp.close(opened)
    return error(said.message)
  end

  upgraded = try Smtp.starttls(said.unwrap!)
  logged = Smtp.login(upgraded, options.username, options.password)
  if not logged.ok?
    Smtp.close(upgraded)
    return logged
  end

  sent = Smtp.send_message(upgraded, message)
  _ = Smtp.quit(upgraded)
  return sent
end

def send_without_password(ctx: BDD.Context, args: List[String]) -> BDD.Context
  message = message_of(ctx, "ana@example.com", "bob@example.com", "Password", "kept?", "")
  return finish(ctx, connect_and_check(options_of(ctx), message))
end

def connect_and_check(options: Smtp.Options, message: Smtp.Message) -> Result[Void]
  client = try Smtp.connect(options)
  if client.options.password != ""
    Smtp.close(client)
    return error("the client still holds the password")
  end

  sent = Smtp.send_message(client, message)
  _ = Smtp.quit(client)
  return sent
end

def session(options: Smtp.Options, first: Smtp.Message, second: Smtp.Message) -> Result[Void]
  client = try Smtp.connect(options)
  sent = Smtp.send_message(client, first)
  if sent.ok?
    sent = Smtp.send_message(client, second)
  end

  if not sent.ok?
    Smtp.close(client)
    return sent
  end

  return Smtp.quit(client)
end

def message_of(ctx: BDD.Context, from: String, to: String, subject: String, text: String, html: String) -> Smtp.Message
  date = FIXED_DATE
  id = FIXED_ID
  if flag(ctx, STAMP)
    date = ""
    id = ""
  end

  return Smtp.Message(
    from: from,
    to: to.split(","),
    subject: subject,
    text: text,
    html: html,
    date: date,
    message_id: id,
  )
end

def options_of(ctx: BDD.Context) -> Smtp.Options
  port = 1
  if BDD.get(ctx, PORT).ok?
    port = JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!
  end

  return Smtp.Options(
    host: text_of(ctx, HOST, "127.0.0.1"),
    port: port,
    security: security_of(text_of(ctx, SECURITY, "starttls")),
    username: text_of(ctx, USERNAME, ""),
    password: text_of(ctx, PASSWORD, ""),
    local_hostname: "client.test",
    ca_file: ca_file_of(ctx),
    timeout_ms: int_of(ctx, TIMEOUT, DEFAULT_TIMEOUT_MS),
  )
end

# The test CA, unless the scenario says the client has only the system's certificates (which do not have it).
def ca_file_of(ctx: BDD.Context) -> String
  if flag(ctx, SYSTEM_TRUST)
    return ""
  end

  return "#{certs_dir()}/ca.pem"
end

def security_of(name: String) -> Smtp.Security
  case name
    "implicit" -> return Smtp.Security.Implicit
    "plain" -> return Smtp.Security.Plain
    _ -> return Smtp.Security.Starttls
  end
end

# Keeps the outcome and, when a peer is running, its transcript: the peer says `closed` once the client has hung up,
# which every outcome does (a QUIT, or a close after an error).
def finish(ctx: BDD.Context, outcome: Result[Void]) -> BDD.Context
  kept = BDD.set(ctx, OUTCOME, JSON.from(outcome.message))
  if not outcome.ok? and outcome.message == ""
    return BDD.assert(kept, false, "the send failed without a message")
  end

  if BDD.get(kept, PORT).ok?
    transcript = read_transcript(kept)
    return BDD.set(
      BDD.set(kept, TRANSCRIPT, JSON.from(transcript.lines.join("\n"))),
      ENDED,
      JSON.from(transcript.ended),
    )
  end

  return kept
end

# `ended` is false when the peer never said `closed`: the client left the connection open.
def read_transcript(ctx: BDD.Context) -> Transcript
  lines: List[String] = []
  for _ in 0...1000
    line = BDD.read_line(ctx, TRANSCRIPT_MS)
    if not line.ok?
      return Transcript(lines: lines, ended: false)
    end

    if line.unwrap! == CLOSED
      return Transcript(lines: lines, ended: true)
    end

    lines = lines.push(line.unwrap!)
  end

  return Transcript(lines: lines, ended: false)
end

def connection_closed(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, flag(ctx, ENDED), "the client left the connection open")
end

def send_succeeds(ctx: BDD.Context, args: List[String]) -> BDD.Context
  message = text_of(ctx, OUTCOME, "")
  return BDD.assert(ctx, message == "", "the send failed: #{message}")
end

def send_fails_with_code(ctx: BDD.Context, args: List[String]) -> BDD.Context
  message = text_of(ctx, OUTCOME, "")
  code = Smtp.error_code(message)
  expected = args[0].to_i!
  return BDD.assert(ctx, code == some(expected), "the error is #{message.inspect}, whose code is #{code}")
end

def send_fails_without_code(ctx: BDD.Context, args: List[String]) -> BDD.Context
  message = text_of(ctx, OUTCOME, "")
  failed = not message.empty? and Smtp.error_code(message).none?
  return BDD.assert(ctx, failed, "the outcome is #{message.inspect}, not an error without a code")
end

def error_mentions(ctx: BDD.Context, args: List[String]) -> BDD.Context
  message = text_of(ctx, OUTCOME, "")
  return BDD.assert(ctx, message.include?(args[0]), "the error is #{message.inspect}, which lacks #{args[0].inspect}")
end

def error_does_not_mention(ctx: BDD.Context, args: List[String]) -> BDD.Context
  message = text_of(ctx, OUTCOME, "")
  return BDD.assert(
    ctx,
    not message.include?(args[0]),
    "the error is #{message.inspect}, which has #{args[0].inspect}",
  )
end

def transcript_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  expected = BDD.doc_string(ctx).strip
  actual = text_of(ctx, TRANSCRIPT, "")
  return BDD.assert(ctx, actual == expected, "the transcript is:\n#{actual}")
end

def transcript_has_line(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = transcript_lines(ctx)
  return BDD.assert(ctx, lines.include?(args[0]), "no line is #{args[0].inspect} in:\n#{lines.join("\n")}")
end

def transcript_has_prefix(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = transcript_lines(ctx)
  found = lines.any? do |line| line.start_with?(args[0]) end
  return BDD.assert(ctx, found, "no line starts with #{args[0].inspect} in:\n#{lines.join("\n")}")
end

def transcript_lacks_prefix(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = transcript_lines(ctx)
  found = lines.any? do |line| line.start_with?(args[0]) end
  return BDD.assert(ctx, not found, "a line starts with #{args[0].inspect} in:\n#{lines.join("\n")}")
end

def transcript_counts_prefix(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = transcript_lines(ctx)
  found = lines.select do |line| line.start_with?(args[1]) end
  return BDD.assert(
    ctx,
    found.size == args[0].to_i!,
    "#{found.size} lines start with #{args[1].inspect}, not #{args[0]}",
  )
end

def transcript_lines(ctx: BDD.Context) -> List[String]
  return text_of(ctx, TRANSCRIPT, "").split("\n")
end

def text_of(ctx: BDD.Context, name: String, default: String) -> String
  value = BDD.get(ctx, name)
  if not value.ok?
    return default
  end

  return JSON.string(value.unwrap!).unwrap_or(default)
end

def int_of(ctx: BDD.Context, name: String, default: Int) -> Int
  value = BDD.get(ctx, name)
  if not value.ok?
    return default
  end

  return JSON.int(value.unwrap!).unwrap_or(default)
end

def flag(ctx: BDD.Context, name: String) -> Bool
  value = BDD.get(ctx, name)
  if not value.ok?
    return false
  end

  return JSON.bool(value.unwrap!).unwrap_or(false)
end

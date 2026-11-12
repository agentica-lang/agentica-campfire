## An SMTP client that sends the messages of `smtp_message.agc`. `Smtp.send` is the call for one message: it connects,
## sends and quits. For several messages on one connection, `connect` gives a `Client`, `send_message` sends on it as
## often as needed and `quit` ends it. `open`, `ehlo`, `starttls` and `login` are the steps `connect` runs, for a
## server that needs them in another order.
##
## Every function returns a `Result`. An `error` for a server that answered has the reply code in its message,
## `smtp 550: a recipient was refused: mailbox unavailable (ana@example.com)`, and `error_code` reads it back. An error
## without a code from the dialogue (a timeout, a connection that broke) starts `smtp: `; one for a message that is not
## valid names what is wrong with it. `error_summary` keeps what is safe for a log. The password of the `Options` is
## never part of an error and is never logged: do not print an `Options`.
##
## STARTTLS is required: a server that does not offer it gets no message, and no password, unless the options say
## `Security.Plain` for a host on this machine. The module imports no other module of the app besides its own message
## builder, so both can move to a package of their own.

import Mail from "smtp_message"

export Mail.Message
export Mail.Field
export Mail.Envelope

# The ports that the `smtp://` and `smtps://` urls of the config use when they name none: STARTTLS on 587 and implicit
# TLS on 465 (RFC 6409 and 8314).
export STARTTLS_PORT = 587
export IMPLICIT_TLS_PORT = 465

# A server that does not answer in a minute is not coming back (the default of aiosmtplib too).
export DEFAULT_TIMEOUT_MS = 60_000

# RFC 5321 4.5.3.2.6: the server may take 10 minutes to accept the message (it scans it, or stores it, before it says
# 250), so the end of the message has its own, longer wait.
export DEFAULT_DATA_TIMEOUT_MS = 600_000

# The most lines a reply may have, so that a server cannot keep a client reading.
MAX_REPLY_LINES = 100

# RFC 5321 4.5.3.1.5 allows a reply line 512 octets with its CRLF, so 510 once the line is read without it. A client
# has no use for a whole reply of more than 32 KiB: 100 lines of 510 octets would be 51,000, so this is the limit that
# a server of many long lines meets first.
MAX_REPLY_LINE_BYTES = 510
MAX_REPLY_BYTES = 32_768

# The server text that goes into an error is cut here: it comes from the other side.
MAX_ERROR_TEXT = 200

# The reply codes the dialogue waits for.
CODE_READY = 220
CODE_OK = 250
CODE_AUTHENTICATED = 235
CODE_CHALLENGE = 334
CODE_START_DATA = 354
CODE_CLOSING = 221
CODE_FORWARDED = 251
CODE_UNAVAILABLE = 421
MIN_REPLY_CODE = 200
MAX_REPLY_CODE = 599

# The code points of the Unicode line, bidirectional and zero-width controls that `server_text` drops (the C1
# controls, 127 to 159, are a range of their own).
ARABIC_LETTER_MARK = 0x061C
ZERO_WIDTH_SPACE = 0x200B
ZERO_WIDTH_JOINER = 0x200D
LEFT_TO_RIGHT_MARK = 0x200E
RIGHT_TO_LEFT_MARK = 0x200F
LINE_SEPARATOR = 0x2028
RIGHT_TO_LEFT_OVERRIDE = 0x202E
LEFT_TO_RIGHT_ISOLATE = 0x2066
POP_DIRECTIONAL_ISOLATE = 0x2069
INHIBIT_SYMMETRIC_SWAPPING = 0x206A
NOMINAL_DIGIT_SHAPES = 0x206F
BYTE_ORDER_MARK = 0xFEFF

AUTH_FAILED = "authentication failed"

CRLF = "\r\n"

# The errors that tell a reply start `smtp NNN:` (see `expect`); `error_code` reads the code back from there.
ERROR_PREFIX = "smtp "
ERROR_CODE_DIGITS = 3
CODE_FIRST_REFUSAL = 400
NUL = String.from_code(0)

## How the connection is protected. `Starttls` starts in plain text and upgrades with STARTTLS, which the server must
## offer (port 587). `Implicit` is TLS from the first byte (port 465). `Plain` never uses TLS and is only for a host
## on this machine (`localhost`, `127.0.0.0/8`, `::1`), such as a mail catcher in development: any other host is an
## error.
export enum Security
  Starttls
  Implicit
  Plain
end

## Where to connect and as whom. `username` and `password` log in when the username is not empty. `local_hostname` is
## the name that EHLO gives: the name of the machine that sends, as other servers can look it up, so it has no default.
## `ca_file` is a PEM file of certificate authorities that replaces the system's. `timeout_ms` is the time for each
## connection, each reply and each write, and `data_timeout_ms` the time for the reply after the message. `password`
## is a secret: never print or log an `Options`.
export struct Options
  host: String
  local_hostname: String
  port: Int = STARTTLS_PORT
  security: Security = Security.Starttls
  username: String = ""
  password: String = ""
  ca_file: String = ""
  timeout_ms: Int = DEFAULT_TIMEOUT_MS
  data_timeout_ms: Int = DEFAULT_DATA_TIMEOUT_MS
end

## An open connection to a server. It belongs to the task that opened it, as every socket does.
export struct Client
  socket: Socket
  options: Options
  secure: Bool
  features: List[String]
end

struct Reply
  code: Int
  lines: List[String]
end

# What `send_message` needs from a message, checked before a connection is made.
struct Prepared
  envelope: Mail.Envelope
  data: String
end

## Sends one message: connects, logs in when the options have a username, sends and quits. The connection is closed
## in every case. The message is checked first, so a bad message never opens a connection.
export def send(message: Mail.Message, options: Options) -> Result[Void]
  prepared = try prepare(message)
  client = try connect(options)
  sent = deliver(client, prepared)
  if not sent.ok?
    close(client)
    return sent
  end

  # The message is delivered; a server that answers QUIT badly does not undo that.
  _ = quit(client)
  ok()
end

## Opens the connection, reads the greeting, says EHLO, upgrades with STARTTLS (for `Security.Starttls`) and logs in
## (when `username` is not empty). On an `error` nothing stays open. The `Client` that it gives no longer holds the
## password: it is not needed once the login is done.
export def connect(options: Options) -> Result[Client]
  opened = try open(options)
  setup(opened)
end

## Opens a TCP connection (TLS from the start for `Security.Implicit`) and reads the greeting of the server. The
## client has not said EHLO yet. The host is taken without the spaces around it, here and for every later use.
export def open(options: Options) -> Result[Client]
  host = options.host.strip
  if options.security == Security.Plain and not loopback?(host)
    return error("smtp: a plain connection is only allowed to this machine, not to #{host}")
  end

  return error("smtp: the timeout must be more than 0 milliseconds") if options.timeout_ms <= 0

  stripped = options.with(host: host)
  socket = try connect_socket(stripped)
  client = Client(socket: socket, options: stripped, secure: stripped.security == Security.Implicit, features: [])
  greeting = read_reply(client, "the greeting")
  if not greeting.ok?
    close(client)
    return error(greeting.message)
  end

  checked = expect(greeting.unwrap!, [CODE_READY], "the server refused the connection")
  if not checked.ok?
    close(client)
    return error(checked.message)
  end

  ok(client)
end

## Says EHLO and keeps the features that the server lists (`STARTTLS`, `AUTH PLAIN LOGIN`). The connection is closed
## by an `error` that is not a refusal (a timeout, a line that is not a reply, a broken connection) and by a 421; it
## stays open for any other refusal, and for a bad `local_hostname`, which sends nothing.
export def ehlo(client: Client) -> Result[Client]
  name = client.options.local_hostname
  if name.empty? or name.include?(" ") or name.bytes.to_a.any? do |byte| byte < 32 or byte > 126 end
    return error("smtp: the local hostname #{name.inspect} is not a host name")
  end

  asked = ask(client, "EHLO #{name}", "EHLO", [CODE_OK], "EHLO refused")
  if not asked.ok?
    close_when_lost(client, asked.message)
    return error(asked.message)
  end

  reply = asked.unwrap!
  # The first line is the server's greeting, the others are its features.
  features = reply.lines.drop(1).map do |line| line.strip.upcase end
  ok(client.with(features: features))
end

## Upgrades the connection with STARTTLS, which the server must have offered, and says EHLO again, since what a server
## offers can change once the connection is private. The client that comes back is the encrypted one, and the one
## that went in is no longer usable. When STARTTLS is refused or fails, or the EHLO after it does, the connection is
## closed: a caller never has to find a half-upgraded one. The `error`s that leave it open are the one for a server
## without STARTTLS, which is no reason to give up the connection (but nothing is sent over it either), and the one
## for a connection that is already encrypted, which nothing was sent over.
export def starttls(client: Client) -> Result[Client]
  return error("smtp: the connection is already encrypted") if client.secure

  if not offers?(client, "STARTTLS")
    return error("smtp: the server does not offer STARTTLS, so nothing is sent over a plain connection")
  end

  upgraded = upgrade(client)
  if not upgraded.ok?
    # Closing twice is fine: the upgrade has closed the plain socket and, when its EHLO failed, the encrypted one.
    close(client)
  end

  upgraded
end

## Logs in with AUTH PLAIN, or AUTH LOGIN when the server only has that. A server that offers neither, and a login
## over a connection that is plain (only possible to this machine), are an `error` that sends nothing and leaves the
## connection open. An `error` for a reply that refuses the login leaves it open too, except a 421; one that is no
## reply (a timeout, a broken connection) closes it.
export def login(client: Client, username: String, password: String) -> Result[Void]
  if not client.secure and not loopback?(client.options.host)
    return error("smtp: the password is only sent over an encrypted connection")
  end

  if username.include?(NUL) or password.include?(NUL)
    return error("smtp: the username and the password must not hold a NUL character")
  end

  outcome = ok()
  if offers_auth?(client, "PLAIN")
    outcome = auth_plain(client, username, password)
  elsif offers_auth?(client, "LOGIN")
    outcome = auth_login(client, username, password)
  else
    return error("smtp: the server offers no AUTH mechanism that this client has (PLAIN or LOGIN)")
  end

  if not outcome.ok? and (lost?(outcome.message) or out_of_step?(outcome.message))
    close(client)
  end

  outcome
end

## Sends a message on the connection: `MAIL FROM`, `RCPT TO` for each recipient, then the message. If the server
## refuses the sender, a recipient or the message, nothing is delivered (the others are not sent), the connection is
## reset for the next message and the `error` has the code of the refusal. An error without a code that comes from the
## dialogue (a timeout, a line that is not a reply) closes the connection, and so does a 421. A bad message, and a
## connection that is plain to a host that is not this machine (nothing is sent: use `starttls`), leave it as it is.
export def send_message(client: Client, message: Mail.Message) -> Result[Void]
  prepared = try prepare(message)
  deliver(client, prepared)
end

## Says QUIT and closes the connection, even when the server does not answer.
export def quit(client: Client) -> Result[Void]
  reply = ask(client, "QUIT", "QUIT", [CODE_CLOSING], "QUIT refused")
  close(client)
  return error(reply.message) if not reply.ok?

  ok()
end

## Closes the connection without saying QUIT.
export def close(client: Client) -> Void
  TCP.close(client.socket)
end

## The code of the reply that an `error` of this module tells, or `none` for an error that has no reply (a timeout, a
## broken connection, a bad message).
export def error_code(message: String) -> Optional[Int]
  colon = ERROR_PREFIX.length + ERROR_CODE_DIGITS
  return none if not message.start_with?(ERROR_PREFIX) or message.length <= colon or message.slice(colon, 1) != ":"

  code = message.slice(ERROR_PREFIX.length, ERROR_CODE_DIGITS).to_i
  return none if not code.ok?

  some(code.unwrap!)
end

## What of an `error` of this module is safe for a log that many people read: the code and the label of a refusal
## (`smtp 550: a recipient was refused`), or the first words of an error without a code (`smtp: timed out waiting for
## the reply to RCPT TO`). It has no server text, no address and no system message. Anything else (a message that is
## not valid, whose error names what is wrong with it, such as an address) is `the message was not valid`.
export def error_summary(message: String) -> String
  parts = message.split(": ")
  return "#{parts[0]}: #{parts[1]}" if error_code(message).some? and parts.size > 1

  return "#{parts[0]}: #{parts[1]}" if message.start_with?("smtp: ") and parts.size > 1

  "the message was not valid"
end

## True for a host on this machine: `localhost`, an address of `127.0.0.0/8` and `::1`. A name that only starts with
## `127.` is not.
export def loopback?(host: String) -> Bool
  name = host.strip.downcase
  return true if name == "localhost" or name == "::1" or name == "[::1]"

  parts = name.split(".")
  return false if parts.size != 4 or parts[0] != "127"

  parts.all? do |part| octet?(part) end
end

def octet?(part: String) -> Bool
  return false if part.empty? or part.length > 3 or not part.split("").all? do |char| digit?(char) end

  part.to_i!() <= 255
end

def digit?(char: String) -> Bool = char.code >= 48 and char.code <= 57

def upgrade(client: Client) -> Result[Client]
  _ = try ask(client, "STARTTLS", "STARTTLS", [CODE_READY], "STARTTLS refused")
  context = try tls_context(client.options)
  encrypted = TLS.upgrade(client.socket, context, tls_host(client.options.host), client.options.timeout_ms)
  return error(network_failure(encrypted.message, "upgrading to TLS")) if not encrypted.ok?

  upgraded = encrypted.unwrap!
  secure = client.with(socket: upgraded, secure: true, features: [])
  said = ehlo(secure)
  if not said.ok?
    close(secure)
  end

  said
end

def prepare(message: Mail.Message) -> Result[Prepared]
  complete = Mail.complete(message)
  envelope = try Mail.envelope(complete)
  data = try Mail.render(complete)
  ok(Prepared(envelope: envelope, data: data))
end

# Each step that fails closes the client it started from (the one before an upgrade, which `starttls` closes itself),
# so no error leaves a connection open.
def setup(opened: Client) -> Result[Client]
  said = ehlo(opened)
  if not said.ok?
    close(opened)
    return error(said.message)
  end

  client = said.unwrap!
  if client.options.security == Security.Starttls
    upgraded = starttls(client)
    if not upgraded.ok?
      close(client)
      return error(upgraded.message)
    end

    client = upgraded.unwrap!
  end

  return ok(client) if client.options.username.empty?

  logged = login(client, client.options.username, client.options.password)
  if not logged.ok?
    close(client)
    return error(logged.message)
  end

  ok(client.with(options: client.options.with(password: "")))
end

def connect_socket(options: Options) -> Result[Socket]
  if options.security == Security.Implicit
    context = try tls_context(options)
    return connected(TLS.connect(tls_host(options.host), options.port, context, options.timeout_ms))
  end

  connected(TCP.connect(tls_host(options.host), options.port, options.timeout_ms))
end

# The system's message names the host and the port, and is more than one line: it goes after the part that a summary
# keeps.
def connected(socket: Result[Socket]) -> Result[Socket]
  return socket if socket.ok?

  error(network_failure(socket.message, "connecting"))
end

def tls_context(options: Options) -> Result[TlsContext]
  context = TLS.client_context(TlsClientOptions(ca_file: options.ca_file))
  return error(network_failure(context.message, "setting up TLS")) if not context.ok?

  context
end

# `[::1]` is how a url writes an IPv6 host; the socket calls take it without the brackets.
def tls_host(host: String) -> String
  return host.slice(1, host.length - 2) if host.start_with?("[") and host.end_with?("]")

  host
end

def offers?(client: Client, feature: String) -> Bool = client.features.any? do |line| line == feature end

# A feature line is `AUTH PLAIN LOGIN` (or the old `AUTH=PLAIN LOGIN`).
def offers_auth?(client: Client, mechanism: String) -> Bool
  client.features.any? do |line| auth_line?(line, mechanism) end
end

def auth_line?(line: String, mechanism: String) -> Bool
  return false if not line.start_with?("AUTH ") and not line.start_with?("AUTH=")

  line.slice(5, line.length - 5).split(" ").include?(mechanism)
end

def auth_plain(client: Client, username: String, password: String) -> Result[Void]
  secret = Base64.strict_encode64("#{NUL}#{username}#{NUL}#{password}".bytes)
  _ = try ask(client, "AUTH PLAIN #{secret}", "AUTH", [CODE_AUTHENTICATED], AUTH_FAILED)
  ok()
end

# The user and the password each answer a 334 challenge.
def auth_login(client: Client, username: String, password: String) -> Result[Void]
  _ = try ask(client, "AUTH LOGIN", "AUTH", [CODE_CHALLENGE], AUTH_FAILED)
  _ = try ask(client, Base64.strict_encode64(username.bytes), "AUTH", [CODE_CHALLENGE], AUTH_FAILED)
  _ = try ask(client, Base64.strict_encode64(password.bytes), "AUTH", [CODE_AUTHENTICATED], AUTH_FAILED)
  ok()
end

# The transaction of one message. After a refusal the connection gets RSET, so the next message starts clean. A lost
# dialogue (see `lost?`), or a RSET that is not accepted, closes the connection instead.
def deliver(client: Client, prepared: Prepared) -> Result[Void]
  # The message is the thing to keep private: a caller that skipped `starttls` does not send it in the clear.
  if not client.secure and not loopback?(client.options.host)
    return error("smtp: nothing is sent over a plain connection to #{client.options.host}: use STARTTLS first")
  end

  sent = transact(client, prepared)
  return sent if sent.ok?

  if lost?(sent.message) or not reset(client)
    close(client)
  end

  sent
end

# True when the server accepted RSET. A server that does not (a refusal, silence, a line that is no reply) leaves a
# dialogue in a state that nobody knows, so the connection is not used again.
def reset(client: Client) -> Bool
  reply = command(client, "RSET", "RSET")
  reply.ok? and reply.unwrap!.code == CODE_OK
end

# True for an error that leaves the dialogue in a state that nobody knows (no reply came, or the server says it is
# going away with a 421), and so for a connection to close.
def lost?(message: String) -> Bool
  code = error_code(message)
  code.none? or code.unwrap! == CODE_UNAVAILABLE
end

# A coded reply during AUTH that is neither the one awaited nor a refusal (4xx or 5xx): the server and the client no
# longer agree on where the exchange is, so nothing more is said on this connection.
def out_of_step?(message: String) -> Bool
  code = error_code(message)
  code.some? and code.unwrap! < CODE_FIRST_REFUSAL
end

def close_when_lost(client: Client, message: String) -> Void
  if lost?(message)
    close(client)
  end
end

def transact(client: Client, prepared: Prepared) -> Result[Void]
  sender = prepared.envelope.sender
  mail = ask(client, "MAIL FROM:<#{sender}>", "MAIL FROM", [CODE_OK], "the sender was refused")
  _ = try about(mail, sender)
  for recipient in prepared.envelope.recipients
    rcpt = ask(client, "RCPT TO:<#{recipient}>", "RCPT TO", [CODE_OK, CODE_FORWARDED], "a recipient was refused")
    _ = try about(rcpt, recipient)
  end

  _ = try ask(client, "DATA", "DATA", [CODE_START_DATA], "the server refused DATA")
  try write(client, "#{dot_stuff(prepared.data)}.#{CRLF}", "the message")
  done = try read_reply_within(client, "the end of the message", client.options.data_timeout_ms)
  _ = try expect(done, [CODE_OK], "the message was refused")
  ok()
end

# The refusal of a command about an address says the address after the server text, so that the label before it holds
# no address and `error_summary` can keep the label alone.
def about(outcome: Result[Reply], address: String) -> Result[Reply]
  return outcome if outcome.ok?

  error("#{outcome.message} (#{address})")
end

# A line of the message that starts with a dot gets another one, so that it is not taken for the end `.` (RFC 5321
# 4.5.2). The data ends with CRLF, so the last piece is empty and the join writes that line end again.
def dot_stuff(data: String) -> String
  pieces = data.split(CRLF).map do |line| stuffed(line) end
  pieces.join(CRLF)
end

def stuffed(line: String) -> String
  return ".#{line}" if line.start_with?(".")

  line
end

# Sends a command and gives its reply when its code is one of `accepted`, else the `error` of the refusal.
def ask(client: Client, line: String, name: String, accepted: List[Int], refusal: String) -> Result[Reply]
  reply = try command(client, line, name)
  expect(reply, accepted, refusal)
end

def command(client: Client, line: String, name: String) -> Result[Reply]
  try write(client, "#{line}#{CRLF}", name)
  read_reply(client, "the reply to #{name}")
end

# The reply when it has one of the codes, else an `error` with the code, what was refused and what the server said.
def expect(reply: Reply, accepted: List[Int], refusal: String) -> Result[Reply]
  return ok(reply) if accepted.include?(reply.code)

  error("#{ERROR_PREFIX}#{reply.code}: #{refusal}: #{server_text(reply.lines.join(" "))}")
end

# What the server said, as text for an error: without control characters (a terminal would obey an escape sequence in
# a log, and the 8-bit CSI of C1 is one) nor the Unicode line and bidi controls (they reorder or split a log line),
# and cut to a length that a log can hold.
def server_text(text: String) -> String
  printable = text.split("").select do |char| not control_code?(char.code) end
  clean = printable.join("")
  return "#{clean.slice(0, MAX_ERROR_TEXT)}..." if clean.length > MAX_ERROR_TEXT

  clean
end

def control_code?(code: Int) -> Bool
  (
    code < 32 or
    (code >= 127 and code <= 159) or
    code == ARABIC_LETTER_MARK or
    (code >= ZERO_WIDTH_SPACE and code <= ZERO_WIDTH_JOINER) or
    code == LEFT_TO_RIGHT_MARK or
    code == RIGHT_TO_LEFT_MARK or
    (code >= LINE_SEPARATOR and code <= RIGHT_TO_LEFT_OVERRIDE) or
    (code >= LEFT_TO_RIGHT_ISOLATE and code <= POP_DIRECTIONAL_ISOLATE) or
    (code >= INHIBIT_SYMMETRIC_SWAPPING and code <= NOMINAL_DIGIT_SHAPES) or
    code == BYTE_ORDER_MARK
  )
end

def write(client: Client, text: String, what: String) -> Result[Void]
  sent = TCP.send(client.socket, text, client.options.timeout_ms)
  return sent if sent.ok?

  error(network_failure(sent.message, "sending #{what}"))
end

# A reply is one or more lines `250-text`, and the last one is `250 text` or just `250` (RFC 5321 4.2). Every line has
# the same code, three digits that start with 2 to 5. The timeout is for the whole reply, so a server that sends a line
# now and then cannot keep the client waiting; the socket is closed when the time is up, as a timeout of a read does.
def read_reply(client: Client, what: String) -> Result[Reply]
  read_reply_within(client, what, client.options.timeout_ms)
end

def read_reply_within(client: Client, what: String, timeout_ms: Int) -> Result[Reply]
  lines: List[String] = []
  code = 0
  deadline = Time.monotonic_ms() + timeout_ms
  received = 0
  for _ in 0...MAX_REPLY_LINES
    remaining = deadline - Time.monotonic_ms()
    if remaining <= 0
      close(client)
      return error("smtp: timed out waiting for #{what}")
    end

    read = TCP.read_line(client.socket, remaining)
    return error(network_failure(read.message, "waiting for #{what}")) if not read.ok?

    line = read.unwrap!
    received += line.bytesize
    if line.bytesize > MAX_REPLY_LINE_BYTES or received > MAX_REPLY_BYTES
      close(client)
      return error("smtp: #{what} is too long")
    end

    number = reply_code(line)
    if number < 0 or (code != 0 and number != code)
      return error("smtp: the server sent a line that is not a reply while #{what} was awaited")
    end

    code = number
    text = ""
    if line.length > 4
      text = line.slice(4, line.length - 4)
    end

    lines = lines.push(text)
    return ok(Reply(code: code, lines: lines)) if line.length == 3 or line.slice(3, 1) == " "
  end

  close(client)
  error("smtp: #{what} has more than #{MAX_REPLY_LINES} lines")
end

# The code of a reply line, or -1 when the line is not one: three digits, the first from 2 to 5, then nothing, a space
# or a hyphen.
def reply_code(line: String) -> Int
  return -1 if line.length < 3 or not line.slice(0, 3).split("").all? do |char| digit?(char) end

  return -1 if line.length > 3 and line.slice(3, 1) != " " and line.slice(3, 1) != "-"

  code = line.slice(0, 3).to_i!()
  return -1 if code < MIN_REPLY_CODE or code > MAX_REPLY_CODE

  code
end

def network_failure(message: String, doing: String) -> String
  return "smtp: timed out #{doing}" if message.include?("timed out")

  "smtp: the connection failed while #{doing}: #{message}"
end

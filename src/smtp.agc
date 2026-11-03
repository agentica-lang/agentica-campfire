## An SMTP client that sends the messages of `smtp_message.agc`. `Smtp.send` is the call for one message: it connects,
## sends and quits. For several messages on one connection, `connect` gives a `Client`, `send_message` sends on it as
## often as needed and `quit` ends it. `open`, `ehlo`, `starttls` and `login` are the steps `connect` runs, for a
## server that needs them in another order.
##
## Every function returns a `Result`. An `error` for a server that answered has the reply code in its message,
## `smtp 550: recipient ana@example.com refused: mailbox unavailable`, and `error_code` reads it back. An error without
## a code (a timeout, a connection that broke, a bad message) starts `smtp: `. The password of the `Options` is
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

# The most lines a reply may have, so that a server cannot keep a client reading.
MAX_REPLY_LINES = 200

# The reply codes the dialogue waits for.
CODE_READY = 220
CODE_OK = 250
CODE_AUTHENTICATED = 235
CODE_CHALLENGE = 334
CODE_START_DATA = 354
CODE_CLOSING = 221

CRLF = "\r\n"
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
## the name that EHLO gives. `ca_file` is a PEM file of certificate authorities that replaces the system's.
## `timeout_ms` is the time for each connection, each reply and each write. `password` is a secret: never print or log
## an `Options`.
export struct Options
  host: String
  port: Int = STARTTLS_PORT
  security: Security = Security.Starttls
  username: String = ""
  password: String = ""
  local_hostname: String = "localhost"
  ca_file: String = ""
  timeout_ms: Int = DEFAULT_TIMEOUT_MS
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
  return ok()
end

## Opens the connection, reads the greeting, says EHLO, upgrades with STARTTLS (for `Security.Starttls`) and logs in
## (when `username` is not empty). On an `error` nothing stays open.
export def connect(options: Options) -> Result[Client]
  opened = try open(options)
  ready = setup(opened)
  if not ready.ok?
    close(opened)
    return error(ready.message)
  end

  return ready
end

## Opens a TCP connection (TLS from the start for `Security.Implicit`) and reads the greeting of the server. The
## client has not said EHLO yet.
export def open(options: Options) -> Result[Client]
  if options.security == Security.Plain and not loopback?(options.host)
    return error("smtp: a plain connection is only allowed to this machine, not to #{options.host}")
  end

  if options.timeout_ms <= 0
    return error("smtp: the timeout must be more than 0 milliseconds")
  end

  socket = try connect_socket(options)
  client = Client(socket: socket, options: options, secure: options.security == Security.Implicit, features: [])
  greeting = read_reply(client, "the greeting")
  if not greeting.ok?
    close(client)
    return error(greeting.message)
  end

  refused = refusal(greeting.unwrap!, [CODE_READY], "the server refused the connection")
  if refused != ""
    close(client)
    return error(refused)
  end

  return ok(client)
end

## Says EHLO and keeps the features that the server lists (`STARTTLS`, `AUTH PLAIN LOGIN`).
export def ehlo(client: Client) -> Result[Client]
  name = client.options.local_hostname
  if name.empty? or name.include?(" ") or name.bytes.to_a.any? do |byte| byte < 32 or byte > 126 end
    return error("smtp: the local hostname #{name.inspect} is not a host name")
  end

  reply = try command(client, "EHLO #{name}", "EHLO")
  refused = refusal(reply, [CODE_OK], "EHLO refused")
  if refused != ""
    return error(refused)
  end

  # The first line is the server's greeting, the others are its features.
  features = reply.lines.drop(1).map do |line| line.strip.upcase end
  return ok(client.with(features: features))
end

## Upgrades the connection with STARTTLS, which the server must have offered, and says EHLO again, since what a server
## offers can change once the connection is private. The old socket is closed whatever happens.
export def starttls(client: Client) -> Result[Client]
  if client.secure
    return error("smtp: the connection is already encrypted")
  end

  if not offers?(client, "STARTTLS")
    return error("smtp: the server does not offer STARTTLS, so nothing is sent over a plain connection")
  end

  reply = try command(client, "STARTTLS", "STARTTLS")
  refused = refusal(reply, [CODE_READY], "STARTTLS refused")
  if refused != ""
    return error(refused)
  end

  context = try tls_context(client.options)
  upgraded = try TLS.upgrade(client.socket, context, tls_host(client.options.host), client.options.timeout_ms)
  secure = client.with(socket: upgraded, secure: true, features: [])
  return ehlo(secure)
end

## Logs in with AUTH PLAIN, or AUTH LOGIN when the server only has that. A server that offers neither, and a login
## over a connection that is plain (only possible to this machine), are an `error`.
export def login(client: Client, username: String, password: String) -> Result[Void]
  if not client.secure and not loopback?(client.options.host)
    return error("smtp: the password is only sent over an encrypted connection")
  end

  if username.include?(NUL) or password.include?(NUL)
    return error("smtp: the username and the password must not hold a NUL character")
  end

  if offers_auth?(client, "PLAIN")
    return auth_plain(client, username, password)
  end

  if offers_auth?(client, "LOGIN")
    return auth_login(client, username, password)
  end

  return error("smtp: the server offers no AUTH mechanism that this client has (PLAIN or LOGIN)")
end

## Sends a message on the connection: `MAIL FROM`, `RCPT TO` for each recipient, then the message. If the server
## refuses the sender, a recipient or the message, nothing is delivered (the others are not sent), the connection is
## reset for the next message and the `error` has the code of the refusal.
export def send_message(client: Client, message: Mail.Message) -> Result[Void]
  prepared = try prepare(message)
  return deliver(client, prepared)
end

## Says QUIT and closes the connection, even when the server does not answer.
export def quit(client: Client) -> Result[Void]
  reply = command(client, "QUIT", "QUIT")
  close(client)
  if not reply.ok?
    return error(reply.message)
  end

  refused = refusal(reply.unwrap!, [CODE_CLOSING], "QUIT refused")
  if refused != ""
    return error(refused)
  end

  return ok()
end

## Closes the connection without saying QUIT.
export def close(client: Client) -> Void
  TCP.close(client.socket)
end

## The code of the reply that an `error` of this module tells, or `none` for an error that has no reply (a timeout, a
## broken connection, a bad message).
export def error_code(message: String) -> Optional[Int]
  if not message.start_with?("smtp ") or message.length < 9 or message.slice(8, 1) != ":"
    return none
  end

  code = message.slice(5, 3).to_i
  if not code.ok?
    return none
  end

  return some(code.unwrap!)
end

## True for a host on this machine: `localhost`, an address of `127.0.0.0/8` and `::1`. A name that only starts with
## `127.` is not.
export def loopback?(host: String) -> Bool
  name = host.strip.downcase
  if name == "localhost" or name == "::1" or name == "[::1]"
    return true
  end

  parts = name.split(".")
  if parts.size != 4 or parts[0] != "127"
    return false
  end

  return parts.all? do |part| octet?(part) end
end

def octet?(part: String) -> Bool
  if part.empty? or part.length > 3 or not part.split("").all? do |char| digit?(char) end
    return false
  end

  return part.to_i!() <= 255
end

def digit?(char: String) -> Bool
  return char.code >= 48 and char.code <= 57
end

def prepare(message: Mail.Message) -> Result[Prepared]
  complete = Mail.complete(message)
  envelope = try Mail.envelope(complete)
  data = try Mail.render(complete)
  return ok(Prepared(envelope: envelope, data: data))
end

def setup(opened: Client) -> Result[Client]
  client = try ehlo(opened)
  if opened.options.security == Security.Starttls
    client = try starttls(client)
  end

  if not client.options.username.empty?
    try login(client, client.options.username, client.options.password)
  end

  return ok(client)
end

def connect_socket(options: Options) -> Result[Socket]
  if options.security == Security.Implicit
    context = try tls_context(options)
    return TLS.connect(tls_host(options.host), options.port, context, options.timeout_ms)
  end

  return TCP.connect(tls_host(options.host), options.port, options.timeout_ms)
end

def tls_context(options: Options) -> Result[TlsContext]
  return TLS.client_context(TlsClientOptions(ca_file: options.ca_file))
end

# `[::1]` is how a url writes an IPv6 host; the socket calls take it without the brackets.
def tls_host(host: String) -> String
  if host.start_with?("[") and host.end_with?("]")
    return host.slice(1, host.length - 2)
  end

  return host
end

def offers?(client: Client, feature: String) -> Bool
  return client.features.any? do |line| line == feature end
end

# A feature line is `AUTH PLAIN LOGIN` (or the old `AUTH=PLAIN LOGIN`).
def offers_auth?(client: Client, mechanism: String) -> Bool
  return client.features.any? do |line| auth_line?(line, mechanism) end
end

def auth_line?(line: String, mechanism: String) -> Bool
  if not line.start_with?("AUTH ") and not line.start_with?("AUTH=")
    return false
  end

  return line.slice(5, line.length - 5).split(" ").include?(mechanism)
end

def auth_plain(client: Client, username: String, password: String) -> Result[Void]
  secret = Base64.strict_encode64("#{NUL}#{username}#{NUL}#{password}".bytes)
  reply = try command(client, "AUTH PLAIN #{secret}", "AUTH")
  refused = refusal(reply, [CODE_AUTHENTICATED], "authentication failed")
  if refused != ""
    return error(refused)
  end

  return ok()
end

def auth_login(client: Client, username: String, password: String) -> Result[Void]
  asked = try command(client, "AUTH LOGIN", "AUTH")
  refused = refusal(asked, [CODE_CHALLENGE], "authentication failed")
  if refused != ""
    return error(refused)
  end

  named = try command(client, Base64.strict_encode64(username.bytes), "AUTH")
  refused = refusal(named, [CODE_CHALLENGE], "authentication failed")
  if refused != ""
    return error(refused)
  end

  answered = try command(client, Base64.strict_encode64(password.bytes), "AUTH")
  refused = refusal(answered, [CODE_AUTHENTICATED], "authentication failed")
  if refused != ""
    return error(refused)
  end

  return ok()
end

# The transaction of one message. After a refusal the connection gets RSET, so the next message starts clean.
def deliver(client: Client, prepared: Prepared) -> Result[Void]
  sent = transact(client, prepared)
  if sent.ok?
    return sent
  end

  if error_code(sent.message).some?
    # A reply that refused: the connection is fine, so put it back at the start. Without a reply (a timeout) the
    # socket is gone and there is nothing to reset.
    _ = command(client, "RSET", "RSET")
  end

  return sent
end

def transact(client: Client, prepared: Prepared) -> Result[Void]
  sender = prepared.envelope.sender
  from = try command(client, "MAIL FROM:<#{sender}>", "MAIL FROM")
  refused = refusal(from, [CODE_OK], "sender #{sender} refused")
  if refused != ""
    return error(refused)
  end

  for recipient in prepared.envelope.recipients
    to = try command(client, "RCPT TO:<#{recipient}>", "RCPT TO")
    refused = refusal(to, [CODE_OK, 251], "recipient #{recipient} refused")
    if refused != ""
      return error(refused)
    end
  end

  start = try command(client, "DATA", "DATA")
  refused = refusal(start, [CODE_START_DATA], "the server refused DATA")
  if refused != ""
    return error(refused)
  end

  try write(client, "#{dot_stuff(prepared.data)}.#{CRLF}", "the message")
  done = try read_reply(client, "the end of the message")
  refused = refusal(done, [CODE_OK], "the message was refused")
  if refused != ""
    return error(refused)
  end

  return ok()
end

# A line of the message that starts with a dot gets another one, so that it is not taken for the end `.` (RFC 5321
# 4.5.2). The data ends with CRLF, so the last piece is empty and the join writes that line end again.
def dot_stuff(data: String) -> String
  return data.split(CRLF).map do |line| stuffed(line) end.join(CRLF)
end

def stuffed(line: String) -> String
  if line.start_with?(".")
    return ".#{line}"
  end

  return line
end

def command(client: Client, line: String, what: String) -> Result[Reply]
  try write(client, "#{line}#{CRLF}", what)
  return read_reply(client, "the reply to #{what}")
end

def write(client: Client, text: String, what: String) -> Result[Void]
  sent = TCP.send(client.socket, text, client.options.timeout_ms)
  if sent.ok?
    return sent
  end

  return error(network_failure(sent.message, "sending #{what}"))
end

# A reply is one or more lines `250-text`, and the last one is `250 text` (RFC 5321 4.2). Every line has the same
# code. The wait for each line has the timeout of the client.
def read_reply(client: Client, what: String) -> Result[Reply]
  lines: List[String] = []
  code = 0
  for _ in 0...MAX_REPLY_LINES
    read = TCP.read_line(client.socket, client.options.timeout_ms)
    if not read.ok?
      return error(network_failure(read.message, "waiting for #{what}"))
    end

    line = read.unwrap!
    number = line.slice(0, 3).to_i
    separator = line.slice(3, 1)
    valid = line.length >= 3 and number.ok? and (line.length == 3 or separator == " " or separator == "-")
    if not valid or (code != 0 and number.unwrap! != code)
      return error("smtp: the server sent a line that is not a reply while #{what} was awaited")
    end

    code = number.unwrap!
    lines = lines.push(line.slice(4, line.length - 4))
    if line.length == 3 or separator == " "
      return ok(Reply(code: code, lines: lines))
    end
  end

  return error("smtp: the reply to #{what} has more than #{MAX_REPLY_LINES} lines")
end

def network_failure(message: String, doing: String) -> String
  if message.include?("timed out")
    return "smtp: timed out #{doing}"
  end

  return "smtp: the connection failed while #{doing}: #{message}"
end

# An empty text when the reply has one of the codes, else the `error` text for the refusal: the code, what was
# refused and what the server said.
def refusal(reply: Reply, accepted: List[Int], what: String) -> String
  if accepted.include?(reply.code)
    return ""
  end

  return "smtp #{reply.code}: #{what}: #{reply.lines.join(" ")}"
end

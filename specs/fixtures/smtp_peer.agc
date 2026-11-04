## A small SMTP server for the specs of `src/campfire/mail/smtp.agc`, written without the code under test. It listens on
## 127.0.0.1 and a free port, serves one connection and writes the dialogue to stdout, one line each: `C: ` for a
## line of the client (the lines of the message too, as they came, dot-stuffed) and `S: ` for a reply. When the
## connection ends it writes `closed` and stops. The first line is `listening on PORT`.
##
## What it does comes from
## the environment, which the steps set: SMTP_PEER_MODE is `plain`, `starttls` (it offers STARTTLS) or `implicit`
## (TLS from the first byte), SMTP_PEER_AUTH the AUTH mechanisms it offers (`PLAIN LOGIN`, none by default),
## SMTP_PEER_REJECT_RCPT an address that gets a 550, SMTP_PEER_STALL a command that it never answers, and
## SMTP_PEER_CERTS the folder with the certificates and SMTP_PEER_CERT the name of the one to use (`server` by default;
## its files are `NAME.pem` and `NAME-key.pem`). The login that it accepts is `ana` with `secret`. In `starttls` mode
## AUTH and MAIL before the upgrade get a 530.
##
## SMTP_PEER_CANNED_VERB is a command (`RCPT`, or `EHLO#2` for its second time) whose answer is the text of
## SMTP_PEER_CANNED instead: lines separated by `|`, each sent as it is, so `250` alone, `OK` or an empty line are
## replies that a client has to survive. `~N` stands for N lines `250-line` and a last `250 end`. Between those lines
## the peer waits SMTP_PEER_LINE_DELAY_MS. `~N:M` is the same with M letters x after `250-` on each line. `^N` is one
## line `550 ` and N letters x. In a line, `<ESC>` is the escape character, `<CSI>` U+009B (a C1 control), `<RLO>`
## U+202E (a bidi override), `<LS>` U+2028 (a line separator), `<ZWJ>` U+200D (zero width) and `<ISS>` U+206A (a
## deprecated format control). SMTP_PEER_DATA_DELAY_MS is how long it waits after the message before it answers
## 250. SMTP_PEER_CONNECTIONS (1 by default) is how many connections it serves one after the other, each ending with
## `closed`.

HANDSHAKE_MS = 5_000
ACCEPT_MS = 10_000
# A client that says nothing for this long is gone; the specs end long before.
IDLE_MS = 10_000

USER = "ana"
PASSWORD = "secret"
NUL = String.from_code(0)

struct Settings
  mode: String
  auth: String
  reject_rcpt: String
  stall: String
  canned_verb: String
  canned: String
  line_delay_ms: Int
  data_delay_ms: Int
  connections: Int
  context: Optional[TlsContext]
end

def main() -> Void
  settings = load_settings()
  listener = open_listener(settings)
  puts("listening on #{TCP.local_port(listener)}")
  IO.flush()
  for _ in 0...settings.connections
    accepted = TCP.accept(listener, ACCEPT_MS)
    if accepted.ok?
      serve(accepted.unwrap!, settings)
    else
      # Implicit TLS: a client that refused the certificate never completes the handshake, which ends up here.
      IO.warn("smtp peer: no client came: #{accepted.message}")
    end

    puts("closed")
    IO.flush()
    if not accepted.ok?
      return
    end
  end
end

def load_settings() -> Settings
  certs = System.env("SMTP_PEER_CERTS").unwrap_or("")
  context: Optional[TlsContext] = none
  if not certs.empty?
    name = System.env("SMTP_PEER_CERT").unwrap_or("server")
    options = TlsServerOptions(cert_file: "#{certs}/#{name}.pem", key_file: "#{certs}/#{name}-key.pem")
    context = some(TLS.server_context(options).unwrap!)
  end

  return Settings(
    mode: System.env("SMTP_PEER_MODE").unwrap_or("plain"),
    auth: System.env("SMTP_PEER_AUTH").unwrap_or(""),
    reject_rcpt: System.env("SMTP_PEER_REJECT_RCPT").unwrap_or(""),
    stall: System.env("SMTP_PEER_STALL").unwrap_or(""),
    canned_verb: System.env("SMTP_PEER_CANNED_VERB").unwrap_or(""),
    canned: System.env("SMTP_PEER_CANNED").unwrap_or(""),
    line_delay_ms: System.env("SMTP_PEER_LINE_DELAY_MS").unwrap_or("0").to_i!,
    data_delay_ms: System.env("SMTP_PEER_DATA_DELAY_MS").unwrap_or("0").to_i!,
    connections: System.env("SMTP_PEER_CONNECTIONS").unwrap_or("1").to_i!,
    context: context,
  )
end

def open_listener(settings: Settings) -> Listener
  if settings.mode == "implicit"
    return TLS.listen("127.0.0.1", 0, settings.context.unwrap!).unwrap!
  end

  return TCP.listen("127.0.0.1", 0).unwrap!
end

def say(socket: Socket, text: String) -> Void
  puts("S: #{text}")
  # A client that has gone fails the send; the next read ends the session.
  _ = TCP.send(socket, "#{text}\r\n", IDLE_MS)
end

def hear(socket: Socket) -> Result[String]
  line = try TCP.read_line(socket, IDLE_MS)
  if line.empty?
    puts("C:")
  else
    puts("C: #{line}")
  end

  return ok(line)
end

# One command after another until QUIT, a stall or the end of the connection. STARTTLS swaps the socket for the
# encrypted one, which is why the socket is a variable of the loop.
def serve(first: Socket, settings: Settings) -> Void
  socket = first
  say(socket, "220 peer.test ready")
  running = true
  secure = settings.mode == "implicit"
  counts: Map[String, Int] = {}
  while running
    heard = hear(socket)
    if not heard.ok?
      return
    end

    line = heard.unwrap!
    verb = line.split(" ")[0].upcase
    if settings.stall == verb
      stall(socket)
      return
    end

    count = counts.get(verb, 0) + 1
    counts = counts.put(verb, count)
    if settings.canned_verb == verb or settings.canned_verb == "#{verb}##{count}"
      say_canned(socket, settings)
      next
    end

    if settings.mode == "starttls" and not secure and (verb == "AUTH" or verb == "MAIL")
      say(socket, "530 5.7.0 start TLS first")
      next
    end

    case verb
      "EHLO" -> ehlo(socket, settings)
      "STARTTLS" ->
        socket = starttls(socket, settings)
        secure = true
      "AUTH" -> auth(socket, settings, line)
      "MAIL" -> say(socket, "250 sender ok")
      "RCPT" -> rcpt(socket, settings, line)
      "DATA" -> data(socket, settings)
      "RSET" -> say(socket, "250 reset")
      "QUIT" -> running = quit(socket)
      _ -> say(socket, "502 command not implemented")
    end
  end
end

def say_canned(socket: Socket, settings: Settings) -> Void
  lines = settings.canned.split("|").map do |line| controls(line) end
  if settings.canned.start_with?("^")
    count = settings.canned.slice(1, settings.canned.length - 1).to_i!
    lines = ["550 #{List.repeat("x", count).join("")}"]
  end

  if settings.canned.start_with?("~")
    sizes = settings.canned.slice(1, settings.canned.length - 1).split(":")
    filler = "line"
    if sizes.size == 2
      filler = List.repeat("x", sizes[1].to_i!).join("")
    end

    lines = List.repeat("250-#{filler}", sizes[0].to_i!).push("250 end")
  end

  for index in 0...lines.size
    if index > 0
      Task.sleep(settings.line_delay_ms)
    end

    say(socket, lines[index])
  end
end

def controls(line: String) -> String
  return line.replace("<ESC>", String.from_code(27))
    .replace("<CSI>", String.from_code(155))
    .replace("<RLO>", String.from_code(8238))
    .replace("<LS>", String.from_code(8232))
    .replace("<ZWJ>", String.from_code(8205))
    .replace("<ISS>", String.from_code(8298))
end

# Never answers: reads until the client gives up and closes.
def stall(socket: Socket) -> Void
  while hear(socket).ok?
    puts("S: (silence)")
  end
end

def quit(socket: Socket) -> Bool
  say(socket, "221 bye")
  return false
end

def ehlo(socket: Socket, settings: Settings) -> Void
  features: List[String] = []
  if settings.mode == "starttls"
    features = features.push("STARTTLS")
  end

  if not settings.auth.empty?
    features = features.push("AUTH #{settings.auth}")
  end

  if features.empty?
    say(socket, "250 peer.test")
    return
  end

  say(socket, "250-peer.test")
  for index in 0...features.size
    separator = "-"
    if index == features.size - 1
      separator = " "
    end

    say(socket, "250#{separator}#{features[index]}")
  end
end

def starttls(socket: Socket, settings: Settings) -> Socket
  say(socket, "220 ready to start TLS")
  upgraded = TLS.upgrade(socket, settings.context.unwrap!, "", HANDSHAKE_MS)
  if not upgraded.ok?
    # The plain socket is closed by the upgrade, so the next read ends the session.
    IO.warn("smtp peer: the TLS handshake failed: #{upgraded.message}")
    return socket
  end

  return upgraded.unwrap!
end

def auth(socket: Socket, settings: Settings, line: String) -> Void
  words = line.split(" ")
  mechanism = ""
  if words.size > 1
    mechanism = words[1].upcase
  end

  offered = settings.auth.split(" ")
  if not offered.include?(mechanism)
    say(socket, "504 mechanism not offered")
    return
  end

  if mechanism == "PLAIN" and words.size > 2
    verdict(
      socket,
      Base64.strict_decode64(words[2]).unwrap!.decode("utf-8").unwrap! == "#{NUL}#{USER}#{NUL}#{PASSWORD}",
    )

    return
  end

  login(socket)
end

# AUTH LOGIN: the server asks for the user, then for the password, each in base64.
def login(socket: Socket) -> Void
  say(socket, "334 VXNlcm5hbWU6")
  user = hear(socket)
  if not user.ok?
    return
  end

  say(socket, "334 UGFzc3dvcmQ6")
  password = hear(socket)
  if not password.ok?
    return
  end

  named = decoded(user.unwrap!)
  secret = decoded(password.unwrap!)
  verdict(socket, named == USER and secret == PASSWORD)
end

def decoded(text: String) -> String
  return Base64.strict_decode64(text).unwrap!.decode("utf-8").unwrap!
end

def verdict(socket: Socket, accepted: Bool) -> Void
  if accepted
    say(socket, "235 2.7.0 authenticated")
    return
  end

  say(socket, "535 5.7.8 credentials rejected")
end

def rcpt(socket: Socket, settings: Settings, line: String) -> Void
  if not settings.reject_rcpt.empty? and line.include?("<#{settings.reject_rcpt}>")
    say(socket, "550 5.1.1 mailbox unavailable")
    return
  end

  say(socket, "250 recipient ok")
end

# The message ends at a line with a single dot. The lines go to the transcript as they came.
def data(socket: Socket, settings: Settings) -> Void
  say(socket, "354 end data with a dot")
  reading = true
  while reading
    heard = hear(socket)
    if not heard.ok? or heard.unwrap! == "."
      reading = false
    end
  end

  Task.sleep(settings.data_delay_ms)
  say(socket, "250 queued as 1")
end

## A small SMTP server for the mail specs, written without the code under test. It listens on 127.0.0.1 and a free
## port, serves one connection after the other and writes the dialogue to stdout, one line each: `C: ` for a line of the
## client (the lines of the message too, as they came, dot-stuffed) and `S: ` for a reply. When a connection ends it
## writes `closed`. The first line is `listening on PORT`.
##
## What it does comes from the environment, which the steps set: SMTP_PEER_AUTH the AUTH mechanisms it offers (`PLAIN
## LOGIN`, none by default), SMTP_PEER_REJECT_RCPT an address that gets a 550, SMTP_PEER_STALL a command that it never
## answers, and SMTP_PEER_CONNECTIONS (1 by default) how many connections it serves. The login that it accepts is `ana`
## with `secret`. It never uses TLS.

private

ACCEPT_MS = 10_000
# A client that says nothing for this long is gone; the specs end long before.
IDLE_MS = 10_000
# A command that is never answered keeps the connection open longer than the mailer of the app waits for its task when
# it stops (`STOP_WAIT_MS` in src/campfire/mail/mailer.agc, 10 s), so the app is always the one that hangs up, never
# the peer.
STALL_MS = 20_000
USER = "ana"
PASSWORD = "secret"
NUL = String.from_code(0)

struct Settings
  auth: String
  reject_rcpt: String
  stall: String
  connections: Int
end

def main() -> Void
  settings = load_settings()
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  puts("listening on #{TCP.local_port(listener)}")
  IO.flush()
  for _ in 0...settings.connections
    accepted = TCP.accept(listener, ACCEPT_MS)
    if accepted.ok?
      serve(accepted.unwrap!, settings)
    end

    puts("closed")
    IO.flush()
    return if not accepted.ok?
  end
end

def load_settings() -> Settings
  Settings(
    auth: System.env("SMTP_PEER_AUTH").unwrap_or(""),
    reject_rcpt: System.env("SMTP_PEER_REJECT_RCPT").unwrap_or(""),
    stall: System.env("SMTP_PEER_STALL").unwrap_or(""),
    connections: System.env("SMTP_PEER_CONNECTIONS").unwrap_or("1").to_i!,
  )
end

def say(socket: TCP.Socket, text: String) -> Void
  puts("S: #{text}")
  # A client that has gone fails the send; the next read ends the session.
  _ = TCP.send(socket, "#{text}\r\n", IDLE_MS)
end

def hear(socket: TCP.Socket, wait_ms: Int = IDLE_MS) -> Result[String]
  line = try TCP.read_line(socket, wait_ms)
  if line.empty?
    puts("C:")
  else
    puts("C: #{line}")
  end

  ok(line)
end

# One command after another until QUIT, a stall or the end of the connection.
def serve(socket: TCP.Socket, settings: Settings) -> Void
  say(socket, "220 peer.test ready")
  running = true
  while running
    heard = hear(socket)
    return if not heard.ok?

    line = heard.unwrap!
    verb = line.split(" ")[0].upcase
    if settings.stall == verb
      stall(socket)
      return
    end

    case verb
      "EHLO" -> ehlo(socket, settings)
      "AUTH" -> auth(socket, settings, line)
      "MAIL" -> say(socket, "250 sender ok")
      "RCPT" -> rcpt(socket, settings, line)
      "DATA" -> data(socket)
      "RSET" -> say(socket, "250 reset")
      "QUIT" -> running = quit(socket)
      _ -> say(socket, "502 command not implemented")
    end
  end
end

# Never answers: reads until the client gives up and closes.
def stall(socket: TCP.Socket) -> Void
  while hear(socket, STALL_MS).ok?
    puts("S: (silence)")
  end
end

def quit(socket: TCP.Socket) -> Bool
  say(socket, "221 bye")
  false
end

def ehlo(socket: TCP.Socket, settings: Settings) -> Void
  if settings.auth.empty?
    say(socket, "250 peer.test")
    return
  end

  say(socket, "250-peer.test")
  say(socket, "250 AUTH #{settings.auth}")
end

def auth(socket: TCP.Socket, settings: Settings, line: String) -> Void
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
def login(socket: TCP.Socket) -> Void
  say(socket, "334 VXNlcm5hbWU6")
  user = hear(socket)
  return if not user.ok?

  say(socket, "334 UGFzc3dvcmQ6")
  password = hear(socket)
  return if not password.ok?

  named = decoded(user.unwrap!)
  secret = decoded(password.unwrap!)
  verdict(socket, named == USER and secret == PASSWORD)
end

def decoded(text: String) -> String = Base64.strict_decode64(text).unwrap!.decode("utf-8").unwrap!

def verdict(socket: TCP.Socket, accepted: Bool) -> Void
  if accepted
    say(socket, "235 2.7.0 authenticated")
    return
  end

  say(socket, "535 5.7.8 credentials rejected")
end

def rcpt(socket: TCP.Socket, settings: Settings, line: String) -> Void
  if not settings.reject_rcpt.empty? and line.include?("<#{settings.reject_rcpt}>")
    say(socket, "550 5.1.1 mailbox unavailable")
    return
  end

  say(socket, "250 recipient ok")
end

# The message ends at a line with a single dot. The lines go to the transcript as they came.
def data(socket: TCP.Socket) -> Void
  say(socket, "354 end data with a dot")
  reading = true
  while reading
    heard = hear(socket)
    if not heard.ok? or heard.unwrap! == "."
      reading = false
    end
  end

  say(socket, "250 queued as 1")
end

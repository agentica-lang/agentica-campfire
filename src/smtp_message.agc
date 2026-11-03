## An email message and its text, as RFC 5322 and MIME write it: the headers, an RFC 2047 subject, a plain text body or
## text and HTML as `multipart/alternative`, CRLF line ends, folded headers and quoted-printable where the text needs
## it. `render` is pure, so the same message always gives the same text. The module imports no other module of the app,
## so it can move to a package of its own with `smtp.agc`.

import UTC from "std/utc"

# The longest header line that folding aims for (RFC 5322 asks for 78 or less, and the line ends take two more).
FOLD_WIDTH = 76

# The most bytes of one RFC 2047 encoded word: 42 bytes make 56 base64 characters, and with `=?UTF-8?B?` and `?=` the
# word has 68, under the 75 that the RFC allows, and `Subject: ` and the word fit in 78 characters.
WORD_BYTES = 42

# A quoted-printable line has at most 76 characters with its soft break `=`.
QP_WIDTH = 75
MAX_BODY_LINE = 76

HEX_DIGITS = "0123456789ABCDEF"
WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
MS_PER_DAY = 86_400_000
UNIX_EPOCH_WEEKDAY = 4

# What a display name may not hold without quotes (RFC 5322 specials).
SPECIALS = Set.new(["(", ")", "<", ">", "[", "]", ":", ";", "@", "\\", ",", ".", "\""])

# What an address may not hold: the specials, the space and the quote make it a mailbox that this module does
# not write.
ADDRESS_FORBIDDEN = Set.new(["(", ")", "<", ">", "[", "]", ":", ";", "\\", ",", "\"", " "])

# Headers that the fields of a `Message` write, so `headers` may not repeat them.
OWN_HEADERS = Set.new([
  "date",
  "from",
  "to",
  "cc",
  "bcc",
  "reply-to",
  "subject",
  "message-id",
  "mime-version",
  "content-type",
  "content-transfer-encoding",
])

## A header that is not one of the fields of a `Message`, such as `List-Unsubscribe`.
export struct Field
  name: String
  value: String
end

## What to send. An address is `ana@example.com` or `Ana <ana@example.com>`, and a name may be any text. `text` or
## `html` (or both: the reader's client picks one) must have something in it. `bcc` addresses get the message but are
## not in its headers. An empty `date` and `message_id` are made by `complete` when the message is sent; a text in them
## is written as it is.
export struct Message
  from: String
  to: List[String]
  subject: String
  text: String = ""
  html: String = ""
  cc: List[String] = []
  bcc: List[String] = []
  reply_to: String = ""
  date: String = ""
  message_id: String = ""
  headers: List[Field] = []
end

## The addresses of the SMTP dialogue, `MAIL FROM` and one `RCPT TO` each, apart from the names in the headers.
export struct Envelope
  sender: String
  recipients: List[String]
end

struct Address
  name: String
  address: String
end

## The message with `date` and `message_id` made when they are empty: the date of now, and a random id at the domain of
## the sender. A sender that is not an address leaves the id empty, and `render` or `envelope` tell what is wrong.
export def complete(message: Message) -> Message
  date = message.date
  if date.empty?
    date = rfc5322_date(Time.now_ms())
  end

  id = message.message_id
  if id.empty?
    id = new_message_id(message.from)
  end

  return message.with(date: date, message_id: id)
end

## The sender and every recipient of `to`, `cc` and `bcc`, without repeats, or an `error` that names the address that
## is wrong or says that there is no recipient.
export def envelope(message: Message) -> Result[Envelope]
  sender = try parse_address(message.from)
  recipients = try parse_all(message.to.concat(message.cc).concat(message.bcc))
  if recipients.empty?
    return error("a message needs at least one recipient")
  end

  addresses = recipients.map do |recipient| recipient.address end
  return ok(Envelope(sender: sender.address, recipients: addresses.uniq))
end

## The message as it goes after `DATA`: the headers, an empty line and the body, with CRLF line ends and a CRLF at the
## end. An `error` is a line break (or another control character) in a header, an address that is not one, no
## recipient or no body.
export def render(message: Message) -> Result[String]
  try check_headers(message)
  if message.text.empty? and message.html.empty?
    return error("a message needs a text or an html body")
  end

  from = try parse_address(message.from)
  to = try parse_all(message.to)
  cc = try parse_all(message.cc)
  bcc = try parse_all(message.bcc)
  reply_to = try parse_optional(message.reply_to)
  if to.empty? and cc.empty? and bcc.empty?
    return error("a message needs at least one recipient")
  end

  lines: List[String] = []
  if not message.date.empty?
    lines = lines.push(fold("Date", message.date))
  end

  lines = lines.push(fold("From", format_address(from)))
  if not to.empty?
    lines = lines.push(fold("To", format_all(to)))
  end

  if not cc.empty?
    lines = lines.push(fold("Cc", format_all(cc)))
  end

  if reply_to.some?
    lines = lines.push(fold("Reply-To", format_address(reply_to.unwrap!)))
  end

  lines = lines.push(fold("Subject", encode_words(message.subject)))
  if not message.message_id.empty?
    lines = lines.push(fold("Message-ID", message.message_id))
  end

  lines = lines.push("MIME-Version: 1.0")
  for field in message.headers
    lines = lines.push(fold(field.name, field.value))
  end

  head = lines.join("\r\n")
  return ok("#{head}\r\n#{body(message)}")
end

# Every value a person wrote goes through here before it becomes part of a line: a CR or LF would end the header and
# start another one (a Bcc, or a body), so nothing with a control character is written, encoded or not. The tab is the
# one exception, in the text of a subject (RFC 5322 allows white space there). A date and an id are ASCII, and so is
# the value of a custom header: only the subject and the display names are text that an encoded word may carry.
def check_headers(message: Message) -> Result[Void]
  strict = [message.from, message.reply_to, message.date, message.message_id]
  strict = strict.concat(message.to).concat(message.cc).concat(message.bcc)
  for value in strict
    if control?(value)
      return error("a header value must not hold a line break or another control character: #{value.inspect}")
    end
  end

  if not ascii?(message.date) or not ascii?(message.message_id)
    return error("the date and the message id must be ASCII")
  end

  if control?(message.subject.replace("\t", " "))
    return error("the subject must not hold a line break or another control character: #{message.subject.inspect}")
  end

  for field in message.headers
    try check_field(field)
  end

  return ok()
end

def check_field(field: Field) -> Result[Void]
  if not token?(field.name)
    return error("the header name #{field.name.inspect} is not valid")
  end

  if OWN_HEADERS.include?(field.name.downcase)
    return error("the header #{field.name} is made from the fields of the message, not from headers")
  end

  if control?(field.value.replace("\t", " "))
    return error("the value of the header #{field.name} must not hold a line break or another control character")
  end

  if not ascii?(field.value)
    return error("the value of the header #{field.name} must be ASCII: only the subject and the names are encoded")
  end

  return ok()
end

def control?(text: String) -> Bool
  return text.bytes.to_a.any? do |byte| byte < 32 or byte == 127 end
end

# A header name is printable ASCII without a colon or a space (an RFC 5322 field name).
def token?(name: String) -> Bool
  if name.empty?
    return false
  end

  return name.bytes.to_a.all? do |byte| byte > 32 and byte < 127 and byte != 58 end
end

# Text that goes in a header as it is: ASCII, and without `=?`, which a reader would take for an encoded word.
def plain_text?(text: String) -> Bool
  return ascii?(text) and not text.include?("=?")
end

def ascii?(text: String) -> Bool
  return text.bytesize == text.length
end

def parse_all(texts: List[String]) -> Result[List[Address]]
  found: List[Address] = []
  for text in texts
    address = try parse_address(text)
    found = found.push(address)
  end

  return ok(found)
end

def parse_optional(text: String) -> Result[Optional[Address]]
  if text.strip.empty?
    return ok(none)
  end

  address = try parse_address(text)
  return ok(some(address))
end

# `ana@example.com` or `Name <ana@example.com>`. The address is ASCII and has one `@` with something on each side.
def parse_address(text: String) -> Result[Address]
  if control?(text)
    return error("the address #{text.inspect} must not hold a line break or another control character")
  end

  value = text.strip
  name = ""
  address = value
  if value.end_with?(">")
    open = value.index_of("<").unwrap_or(-1)
    if open < 0
      return error("the address #{text.inspect} has a > without a <")
    end

    name = unquote(value.slice(0, open).strip)
    address = value.slice(open + 1, value.length - open - 2).strip
  end

  if name.include?("\"") or name.include?("\\") or name.include?("<") or name.include?(">")
    return error("the name of the address #{text.inspect} must not hold a quote, a backslash or an angle bracket")
  end

  parts = address.split("@")
  valid = parts.size == 2 and not parts[0].empty? and not parts[1].empty? and ascii?(address)
  if not valid or address.split("").any? do |char| ADDRESS_FORBIDDEN.include?(char) end
    return error("#{text.inspect} is not an address of the form name@domain")
  end

  return ok(Address(name: name, address: address))
end

def unquote(name: String) -> String
  if name.length >= 2 and name.start_with?("\"") and name.end_with?("\"")
    return name.slice(1, name.length - 2)
  end

  return name
end

def format_all(addresses: List[Address]) -> String
  return addresses.map do |address| format_address(address) end.join(", ")
end

def format_address(address: Address) -> String
  if address.name.empty?
    return address.address
  end

  if not plain_text?(address.name)
    return "#{encode_words(address.name)} <#{address.address}>"
  end

  if address.name.split("").any? do |char| SPECIALS.include?(char) end
    return "\"#{address.name}\" <#{address.address}>"
  end

  return "#{address.name} <#{address.address}>"
end

# Text that is not ASCII goes in RFC 2047 encoded words, UTF-8 and base64, each with whole characters, so that no
# word splits a character and a reader that joins the words gets the text back.
def encode_words(text: String) -> String
  if plain_text?(text)
    return text
  end

  words: List[String] = []
  chunk: List[String] = []
  size = 0
  for char in text.split("")
    if size + char.bytesize > WORD_BYTES
      words = words.push(encoded_word(chunk))
      chunk = []
      size = 0
    end

    chunk = chunk.push(char)
    size += char.bytesize
  end

  words = words.push(encoded_word(chunk))
  return words.join(" ")
end

def encoded_word(chars: List[String]) -> String
  return "=?UTF-8?B?#{Base64.strict_encode64(chars.join("").bytes)}?="
end

# `Name: value`, broken at spaces into lines that start with that space (a reader that unfolds removes only the line
# end, so the value comes back as it was, runs of spaces included). The first word stays on the line of the name, so no
# line is only `Name:`; a word that does not fit on a line stays whole.
def fold(name: String, value: String) -> String
  if value.empty?
    return "#{name}:"
  end

  lines: List[String] = []
  line = "#{name}:"
  has_word = false
  for piece in value.split(" ")
    if has_word and not piece.empty? and line.length + 1 + piece.length > FOLD_WIDTH
      lines = lines.push(line)
      line = " #{piece}"
    else
      line = "#{line} #{piece}"
    end

    if not piece.empty?
      has_word = true
    end
  end

  return lines.push(line).join("\r\n")
end

# The content headers, an empty line and the body, with a final line end.
def body(message: Message) -> String
  if message.html.empty?
    return "#{part("text/plain", message.text)}\r\n"
  end

  if message.text.empty?
    return "#{part("text/html", message.html)}\r\n"
  end

  boundary = boundary_for(message.text, message.html)
  text = chomp(part("text/plain", message.text))
  html = chomp(part("text/html", message.html))
  head = "Content-Type: multipart/alternative; boundary=\"#{boundary}\"\r\n"
  return "#{head}\r\n--#{boundary}\r\n#{text}\r\n--#{boundary}\r\n#{html}\r\n--#{boundary}--\r\n"
end

# The headers of a body part, an empty line and its text, without a final line end.
def part(content_type: String, text: String) -> String
  normal = crlf(text)
  encoding = "7bit"
  encoded = normal
  if not plain_body?(normal)
    encoding = "quoted-printable"
    encoded = quoted_printable(normal)
  end

  head = "Content-Type: #{content_type}; charset=utf-8\r\nContent-Transfer-Encoding: #{encoding}"
  return "#{head}\r\n\r\n#{chomp(encoded)}"
end

def chomp(text: String) -> String
  if text.end_with?("\r\n")
    return text.slice(0, text.length - 2)
  end

  return text
end

# The same message always gets the same boundary, since it comes from the parts. A boundary must not be in a part, so
# it grows until it is not.
def boundary_for(text: String, html: String) -> String
  digest = Digest.sha256_hexdigest("#{text}\n#{html}".bytes)
  boundary = "=_#{digest.slice(0, 32)}"
  while text.include?(boundary) or html.include?(boundary)
    boundary = "#{boundary}x"
  end

  return boundary
end

def crlf(text: String) -> String
  return text.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\r\n")
end

# 7bit is allowed for ASCII text with short lines and no control characters but the tab.
def plain_body?(text: String) -> Bool
  if not ascii?(text)
    return false
  end

  if text.bytes.to_a.any? do |byte| (byte < 32 and byte != 9 and byte != 10 and byte != 13) or byte == 127 end
    return false
  end

  return text.split("\r\n").all? do |line| line.length <= MAX_BODY_LINE end
end

# RFC 2045 quoted-printable of text with CRLF line ends. Each line is cut at 75 characters with a soft break `=`, and
# a space or tab that ends a line is written as `=20` or `=09` (a reader drops trailing white space).
def quoted_printable(text: String) -> String
  return text.split("\r\n").map do |line| qp_line(line) end.join("\r\n")
end

def qp_line(line: String) -> String
  bytes = line.bytes.to_a
  out: List[String] = []
  width = 0
  last = bytes.size - 1
  for index in 0..last
    token = qp_token(bytes[index], index == last)
    if width + token.length > QP_WIDTH
      out = out.push("=\r\n")
      width = 0
    end

    out = out.push(token)
    width += token.length
  end

  return out.join("")
end

def qp_token(byte: Int, last: Bool) -> String
  needs_hex = byte == 61 or byte > 126 or (byte < 32 and byte != 9) or (last and (byte == 9 or byte == 32))
  if needs_hex
    return "=#{HEX_DIGITS.slice(byte / 16, 1)}#{HEX_DIGITS.slice(byte % 16, 1)}"
  end

  return String.from_code(byte)
end

# `Tue, 03 Nov 2026 10:55:02 +0000`, the date of RFC 5322, from Unix milliseconds.
def rfc5322_date(ms: Int) -> String
  parts = UTC.parts(ms)
  weekday = WEEKDAYS[((ms / MS_PER_DAY + UNIX_EPOCH_WEEKDAY) % 7 + 7) % 7]
  month = MONTHS[parts.month - 1]
  time = "#{two(parts.hour)}:#{two(parts.minute)}:#{two(parts.second)}"
  return "#{weekday}, #{two(parts.day)} #{month} #{parts.year} #{time} +0000"
end

def two(number: Int) -> String
  if number < 10
    return "0#{number}"
  end

  return "#{number}"
end

# `<random@domain>`: the domain of the sender keeps the id unique to this sender. A sender without an address has none.
def new_message_id(sender: String) -> String
  parsed = parse_address(sender)
  if not parsed.ok?
    return ""
  end

  domain = parsed.unwrap!.address.split("@")[1]
  return "<#{SecureRandom.hex(16)}@#{domain}>"
end

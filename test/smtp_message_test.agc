import Mail from "../src/smtp_message"

DATE = "Tue, 03 Nov 2026 10:55:02 +0000"
ID = "<t@example.com>"

def message(subject: String, text: String) -> Mail.Message
  return Mail.Message(
    from: "ana@example.com",
    to: ["bob@example.com"],
    subject: subject,
    text: text,
    date: DATE,
    message_id: ID,
  )
end

# The lines of the rendered message, so that a test reads them one by one.
def lines_of(rendered: Result[String]) -> List[String]
  return rendered.unwrap!.split("\r\n")
end

# The words of an RFC 2047 header value `=?UTF-8?B?...?= =?UTF-8?B?...?=`, decoded and joined.
def decode_words(value: String) -> String
  pieces = value.split(" ").map do |word| decode_word(word) end
  return pieces.join("")
end

def decode_word(word: String) -> String
  body = word.slice(10, word.length - 12)
  return String.from_bytes(Base64.strict_decode64(body).unwrap!).unwrap!
end

def main() -> Void
  Test.run([
    Test.test("a plain text message is the headers, an empty line and the text, with CRLF at every line end") do
      Test.eq(
        Mail.render(message("Hello", "Hi Bob.\nSee you.")),
        ok(
          [
            "Date: #{DATE}",
            "From: ana@example.com",
            "To: bob@example.com",
            "Subject: Hello",
            "Message-ID: #{ID}",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 7bit",
            "",
            "Hi Bob.",
            "See you.",
            "",
          ].join("\r\n"),
        ),
      )
    end,
    Test.test(
      "a subject and a name that are not ASCII are encoded words that decode to the text, 75 characters at most",
    ) do
      subject = "Restablecer tu contraseña de Campfire, ahora mismo y sin esperar más tiempo del necesario"
      sent = Mail.Message(
        from: "Ana Gómez <ana@example.com>",
        to: ["bob@example.com"],
        subject: subject,
        text: "x",
        date: DATE,
        message_id: ID,
      )

      lines = lines_of(Mail.render(sent))
      subject_words = lines.drop_while do |line| not line.start_with?("Subject:") end
        .take_while do |line| line.start_with?("Subject:") or line.start_with?(" ") end
        .map do |line| line.replace("Subject:", "").strip end
        .select do |line| not line.empty? end

      try Test.eq(decode_words(subject_words.join(" ")), subject)
      try Test.eq(subject_words.all? do |word| word.length <= 75 end, true)
      Test.eq(decode_words(decode_name(lines)), "Ana Gómez")
    end,
    Test.test(
      "a body with non-ASCII text or a long line is quoted-printable, cut at 76 characters with a soft break",
    ) do
      long = List.repeat("a", 80).join("")
      lines = lines_of(Mail.render(message("s", "señor = trailing \n#{long}")))
      try Test.eq(lines.include?("Content-Transfer-Encoding: quoted-printable"), true)
      try Test.eq(lines.include?("se=C3=B1or =3D trailing=20"), true)
      try Test.eq(lines.include?("#{List.repeat("a", 75).join("")}="), true)
      Test.eq(lines.include?("aaaaa"), true)
    end,
    Test.test(
      "text and html make a multipart/alternative with a boundary that is the same every time and in no part",
    ) do
      both = message("s", "plain").with(html: "<p>html</p>")
      first = Mail.render(both)
      try Test.eq(first, Mail.render(both))
      lines = lines_of(first)
      boundary = lines.find do |line| line.start_with?("--=_") end.unwrap!
      try Test.eq(
        lines.include?("Content-Type: multipart/alternative; boundary=\"#{boundary.slice(2, boundary.length - 2)}\""),
        true,
      )

      try Test.eq(lines.include?("#{boundary}--"), true)
      try Test.eq(lines.include?("Content-Type: text/plain; charset=utf-8"), true)
      Test.eq(lines.include?("Content-Type: text/html; charset=utf-8"), true)
    end,
    Test.test("a line break in any header value is refused, encoded or not") do
      try Test.error?(Mail.render(message("Hi\r\nBcc: eve@example.com", "x")))
      try Test.error?(Mail.render(message("Hi\nBcc: eve@example.com", "x")))
      try Test.error?(Mail.render(message("Hola señor\r\nBcc: eve@example.com", "x")))
      try Test.error?(Mail.render(message("s", "x").with(from: "ana@example.com\r\nBcc: eve@example.com")))
      try Test.error?(Mail.render(message("s", "x").with(to: ["bob@example.com\r\nBcc: eve@example.com"])))
      try Test.error?(Mail.render(message("s", "x").with(reply_to: "a@b.com\nX: y")))
      try Test.error?(Mail.render(message("s", "x").with(headers: [Mail.Field(name: "X-A", value: "b\r\nBcc: c")])))
      try Test.error?(Mail.render(message("s", "x").with(headers: [Mail.Field(name: "X-A\r\nBcc", value: "b")])))
      Test.ok?(
        Mail.render(
          message("s", "x").with(headers: [Mail.Field(name: "List-Unsubscribe", value: "<mailto:u@example.com>")]),
        ),
      )
    end,
    Test.test("a message with no recipient, no body, a bad address or a header that a field makes is refused") do
      try Test.error?(Mail.render(message("s", "x").with(to: [])))
      try Test.error?(Mail.render(message("s", "")))
      try Test.error?(Mail.render(message("s", "x").with(from: "not an address")))
      try Test.error?(Mail.render(message("s", "x").with(to: ["bob@"])))
      try Test.error?(Mail.render(message("s", "x").with(to: ["Bob <bob@example.com"])))
      try Test.error?(
        Mail.render(message("s", "x").with(headers: [Mail.Field(name: "Bcc", value: "eve@example.com")])),
      )

      Test.error?(Mail.render(message("s", "x").with(headers: [Mail.Field(name: "content-type", value: "text/html")])))
    end,
    Test.test("the envelope has the sender and every recipient once, bcc included, and bcc is not in the headers") do
      sent = message("s", "x").with(
        to: ["Bob <bob@example.com>", "cy@example.com"],
        cc: ["bob@example.com"],
        bcc: ["eve@example.com"],
      )

      try Test.eq(
        Mail.envelope(sent),
        ok(
          Mail.Envelope(
            sender: "ana@example.com",
            recipients: ["bob@example.com", "cy@example.com", "eve@example.com"],
          ),
        ),
      )

      rendered = Mail.render(sent).unwrap!
      try Test.eq(rendered.include?("eve@example.com"), false)
      Test.eq(rendered.include?("Cc: bob@example.com"), true)
    end,
    Test.test("a long list of recipients is folded under 78 characters, and complete fills the date and the id") do
      many = message("s", "x").with(
        to: [
          "recipient-number-one@example.com", "recipient-number-two@example.com", "recipient-number-three@example.com",
        ],
      )

      try Test.eq(lines_of(Mail.render(many)).all? do |line| line.length <= 78 end, true)
      stamped = Mail.complete(message("s", "x").with(date: "", message_id: ""))
      try Test.eq(stamped.date.end_with?(" +0000"), true)
      Test.eq(stamped.message_id.end_with?("@example.com>"), true)
    end,
  ])
end

# The display name of the From line, decoded: an encoded word before ` <ana@example.com>`.
def decode_name(lines: List[String]) -> String
  line = lines.find do |candidate| candidate.start_with?("From: ") end.unwrap!
  return line.slice(6, line.length - 6 - " <ana@example.com>".length)
end

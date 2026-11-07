## Links in the text of a clean message body, as Campfire's `MessagesHelper#auto_link_text` does when it shows a message
## (it hands each text node outside a link to `auto_link` of the rails_autolink gem). The body is what
## `HtmlSanitizer.sanitize` wrote, so a `<` starts a tag and no other text has one, and a tag has no attribute but a
## link's. A link shows as `<a target="_blank" href="URL" rel="noopener noreferrer">`, an email address as the same with
## a `mailto:` address.
##
## Compared with Rails:
## - `rel="noopener noreferrer"` is added; Rails writes `target="_blank"` only.
## - the letters of a URL that are not ASCII count as letters at its end, except the usual punctuation and symbols of
##   Unicode (the quotes and dashes of a phone, CJK stops); Rails asks Onigmo for `\p{Word}`. An email address is
##   ASCII only.

import Regex from "std/regex"

# What `auto_link` takes as the start of a URL: one of its schemes and `//`, or `www.`; it goes on to the next space,
# `<`, `"` or no-break space. The first group is the scheme and its colon. A literal cannot be broken over lines.
URL = /(?i)(?:((?:ed2k|ftp|http|https|irc|mailto|news|gopher|nntp|telnet|webcal|xmpp|callto|feed|svn|urn|aim|rsync|tag|ssh|sftp|rtsp|afs|file):)\/\/|www\.)[^\s<"\x{A0}]+/

# An address, as rails_autolink writes it; a match that has more of the local part before it is not one.
EMAIL = /[\w.!#$%+-]\.?[\w.!#$%&'*\/=?^`{|}~+-]*@[\w-]+(?:\.[\w-]+)+/

EMAIL_LOCAL = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.!#$%&'*/=?^`{|}~+-".split(""))

# The closing characters that stay in a URL when it has more openings than they have closings.
BRACKETS = {"]": "[", ")": "(", "}": "{"}

# Besides letters and digits, the characters that a URL may end with.
URL_END = Set.new(["/", "-", "=", ";", "_"])

LINK_ATTRIBUTES = "target=\"_blank\""
LINK_REL = "rel=\"noopener noreferrer\""

# The characters from 128 up that are not letters, as ranges of code points (first and last).
SYMBOL_RANGES = [
  [128, 169],
  [171, 180],
  [182, 185],
  [187, 191],
  [215, 215],
  [247, 247],
  [8192, 8303],
  [8592, 11263],
  [12288, 12351],
  [65281, 65295],
  [65306, 65312],
  [126976, 129791],
]

## `clean` with the URLs and the email addresses of its text made links. A text that has none comes back as it is.
export def link(clean: String) -> String
  if not linkable?(clean)
    return clean
  end

  parts = clean.split("<")
  out = [link_text(parts[0])]
  in_link = false
  for part in parts.drop(1)
    stop = part.index_of(">")
    if stop.none?
      out = out.push("<#{part}")
    else
      tag = part.slice(0, stop.unwrap!)
      text = part.slice(stop.unwrap! + 1, part.length - stop.unwrap! - 1)
      if tag == "a" or tag.start_with?("a ")
        in_link = true
      elsif tag == "/a"
        in_link = false
      end

      out = out.push("<#{tag}>")
      if in_link
        out = out.push(text)
      else
        out = out.push(link_text(text))
      end
    end
  end

  return out.join("")
end

# Only text with a colon, an `@` or `www.` can hold what `URL` or `EMAIL` matches.
def linkable?(text: String) -> Bool
  return text.include?(":") or text.include?("@") or text.downcase.include?("www.")
end

# URLs first; the text between them is searched for addresses, as `auto_link` does, and an address inside a URL is
# part of the URL.
def link_text(text: String) -> String
  if not linkable?(text)
    return text
  end

  out: List[String] = []
  cursor = 0
  for found in Regex.find_all(text, URL)
    out = out.push(link_emails(text.slice(cursor, found.start - cursor)))
    out = out.push(link_url(found))
    cursor = found.stop
  end

  return out.push(link_emails(text.slice(cursor, text.length - cursor))).join("")
end

def link_emails(text: String) -> String
  if not text.include?("@")
    return text
  end

  out: List[String] = []
  cursor = 0
  for found in Regex.find_all(text, EMAIL)
    # `auto_link` only starts an address where its local part starts.
    if found.start > 0 and EMAIL_LOCAL.include?(text.slice(found.start - 1, 1))
      next
    end

    out = out.push(text.slice(cursor, found.start - cursor))
    out = out.push("<a #{LINK_ATTRIBUTES} href=\"mailto:#{found.text}\" #{LINK_REL}>#{found.text}</a>")
    cursor = found.stop
  end

  return out.push(text.slice(cursor, text.length - cursor)).join("")
end

# The link of one match of `URL`. The punctuation at its end is not part of it (a closing bracket stays when the URL
# opened one), nor is a final `&gt;`; they follow the link as text.
def link_url(found: Regex.Match) -> String
  chars = found.text.split("")
  # How many of each bracket the URL has, counted once so that a long run of closing brackets costs a pass, not one
  # for each.
  seen = {"[": 0, "(": 0, "{": 0, "]": 0, ")": 0, "}": 0}
  for c in chars
    if seen.key?(c)
      seen = seen.put(c, seen[c] + 1)
    end
  end

  size = chars.size
  while size > 0 and not word_char?(chars[size - 1])
    last = chars[size - 1]
    size -= 1
    opening = BRACKETS.get(last)
    if opening.some?
      seen = seen.put(last, seen[last] - 1)
      if seen[opening.unwrap!] > seen[last]
        size += 1
        break
      end
    end
  end

  href = chars.take(size).join("")
  after = chars.drop(size).join("")
  closing = ""
  if href.end_with?("&gt;")
    href = href.slice(0, href.length - 4)
    closing = "&gt;"
  end

  target = href
  if not found.groups[1].matched
    target = "http://#{href}"
  end

  link = "<a #{LINK_ATTRIBUTES} href=\"#{target}\" #{LINK_REL}>#{href}</a>"
  return "#{link}#{after}#{closing}"
end

# A letter, a digit, `_` or another character that ends a URL: the ones of `URL_END` and, past ASCII, any that is
# not punctuation or a symbol.
def word_char?(character: String) -> Bool
  code = character.code
  if code < 128
    return (
      URL_END.include?(character) or
      (code >= 48 and code <= 57) or
      (code >= 65 and code <= 90) or
      (code >= 97 and code <= 122)
    )
  end

  return not SYMBOL_RANGES.any? do |range| code >= range[0] and code <= range[1] end
end

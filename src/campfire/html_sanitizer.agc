## An allowlist sanitizer for the HTML of a stored message body (Action Text, as the Rails Campfire wrote it), so the
## body can be shown with `<%== %>`. `sanitize` reads the text once and writes a new text that is made only of what
## this file writes: the tags of `ALLOWED_TAGS` with no attribute (a link has `href` and `rel`, nothing else), text
## with `<`, `>` and `&` escaped, and every tag closed. Nothing of the input is copied into the output except text and
## the value of a link, which is checked and escaped. What it does not know it drops: a tag that is not allowed goes
## and its text stays, a script and its kind go with their content (an end tag that never comes takes the rest of
## the text), and a comment goes. It halts on no input.
##
## Compared with the Rails side, which this follows (the lists are in `app/helpers/content_filters/sanitize_tags.rb`
## of basecamp/once-campfire, over the defaults of rails-html-sanitizer: `SafeListSanitizer.allowed_tags` and
## `allowed_attributes` in
## https://github.com/rails/rails-html-sanitizer/blob/master/lib/rails/html/sanitizer.rb and the URL schemes of
## Loofah, https://github.com/flavorjones/loofah/blob/main/lib/loofah/html5/safelist.rb):
## - fewer tags: Rails also lets through u, mark, h2 to h6, hr, span, sub, sup, dl, dt, dd, abbr, address, cite, ins,
##   kbd, samp, small, time, tt, var, figure and figcaption; each is one more word in `ALLOWED_TAGS`.
## - fewer attributes: Rails keeps `class`, `title`, `alt`, `src`, `width`, `height`, `data-language` and a few more;
##   here only `href` of a link survives (and `rel`, which is written, not copied).
## - schemes: Loofah's list has more (ftp, tel, ...); here only http, https and mailto, and a relative address.
## - `<a>` with no usable `href` is dropped (its text stays); Rails keeps the tag without the attribute.
## - tags that are mis-nested are closed in order; Rails (Nokogiri) rebuilds the tree the way a browser does.

import HTML from "std/html"

# The tags that are kept, with the attributes dropped. `br` is void, `a` is handled apart.
ALLOWED_TAGS = Set.new([
  "p",
  "br",
  "div",
  "strong",
  "em",
  "b",
  "i",
  "s",
  "del",
  "code",
  "pre",
  "blockquote",
  "ul",
  "ol",
  "li",
  "h1",
  "a",
  "table",
  "thead",
  "tbody",
  "tfoot",
  "tr",
  "th",
  "td",
])

# The tags that go with everything in them. The ones with raw text (script, style, textarea, title, iframe, xmp,
# noembed, noframes, noscript, plaintext) end at their own end tag, so a `<` in them is not a tag; the others are
# there so that what they hold (a form, a vector drawing, a template) never reaches the page.
DROPPED_WITH_CONTENT = Set.new([
  "script",
  "style",
  "textarea",
  "title",
  "iframe",
  "xmp",
  "noembed",
  "noframes",
  "noscript",
  "plaintext",
  "template",
  "object",
  "svg",
  "math",
])

ALLOWED_SCHEMES = Set.new(["http", "https", "mailto"])

# A link is the one tag with a rel: the page that it opens gets no handle on this one.
LINK_REL = "noopener noreferrer"

# The depth of open tags. A message is a few levels deep; the cap keeps the cost of closing a tag from growing with
# the input, and a tag past it is dropped.
MAX_DEPTH = 64

# The longest entity that is let through as it is (`&thinsp;`): a name or digits then `;`.
MAX_ENTITY = 32

NUL = String.from_code(0)
FORM_FEED = String.from_code(12)
WHITESPACE = Set.new([" ", "\t", "\n", "\r", FORM_FEED])
LETTERS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".split(""))
DIGITS = Set.new("0123456789".split(""))
HEX_DIGITS = Set.new("0123456789abcdefABCDEF".split(""))
ENTITY_CHARS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".split(""))

# Where the name of a tag ends, where the name of an attribute ends, and what lies between attributes. The HTML
# tokenizer takes an `=` at the start of an attribute name as part of the name, so the name always has one character.
NAME_END = Set.new([" ", "\t", "\n", "\r", FORM_FEED, "/", ">"])
ATTRIBUTE_END = Set.new([" ", "\t", "\n", "\r", FORM_FEED, "/", ">", "="])
BETWEEN_ATTRIBUTES = Set.new([" ", "\t", "\n", "\r", FORM_FEED, "/"])
UNQUOTED_END = Set.new([" ", "\t", "\n", "\r", FORM_FEED, ">"])
DOUBLE_QUOTE = Set.new(["\""])
SINGLE_QUOTE = Set.new(["'"])

# What may follow `</script` for it to be that end tag (and "" is the end of the text).
AFTER_END_NAME = Set.new(["", " ", "\t", "\n", "\r", FORM_FEED, "/", ">"])
URL_DELIMITERS = Set.new([":", "/", "?", "#"])

# Some text of the input and the place after it.
struct Run
  text: String
  next: Int
end

struct Tag
  name: String
  closing: Bool
  href: Optional[String]
  next: Int
end

# What one `<` makes: the HTML to write, the open tags after it, and where the input goes on.
struct Piece
  html: String
  open: List[String]
  next: Int
end

## The safe HTML of `html`. A text with no markup comes back escaped; a text with markup comes back with only the
## allowed tags, closed, and without any attribute but the `href` of a link that is http, https, mailto or relative.
export def sanitize(html: String) -> String
  # A NUL is dropped before anything reads the text: a browser ignores it in a name, so `<scr\0ipt>` is a script.
  cs = html.replace(NUL, "").split("")
  n = cs.size
  out: List[String] = []
  open: List[String] = []
  i = 0
  while i < n
    c = cs[i]
    if c == "<"
      piece = markup(cs, n, i, open)
      if not piece.html.empty?
        out = out.push(piece.html)
      end

      open = piece.open
      i = piece.next
    elsif c == ">"
      out = out.push("&gt;")
      i += 1
    elsif c == "&"
      stop = entity_end(cs, n, i)
      if stop < 0
        out = out.push("&amp;")
        i += 1
      else
        while i < stop
          out = out.push(cs[i])
          i += 1
        end
      end
    else
      out = out.push(c)
      i += 1
    end
  end

  return out.push(closing_tags(open, 0)).join("")
end

# Handles the `<` at `start`: a tag, a comment, or a lone `<` that is text.
def markup(cs: List[String], n: Int, start: Int, open: List[String]) -> Piece
  after = at(cs, n, start + 1)
  if after == "!"
    if at(cs, n, start + 2) == "-" and at(cs, n, start + 3) == "-"
      return Piece(html: "", open: open, next: comment_end(cs, n, start + 4))
    end

    return Piece(html: "", open: open, next: bogus_end(cs, n, start + 2))
  end

  if after == "?"
    return Piece(html: "", open: open, next: bogus_end(cs, n, start + 2))
  end

  if after == "/" and not LETTERS.include?(at(cs, n, start + 2))
    return Piece(html: "", open: open, next: bogus_end(cs, n, start + 2))
  end

  if after == "/" or LETTERS.include?(after)
    return tag_piece(cs, n, start, open)
  end

  return Piece(html: "&lt;", open: open, next: start + 1)
end

def tag_piece(cs: List[String], n: Int, start: Int, open: List[String]) -> Piece
  read = read_tag(cs, n, start)
  # A tag that the text ends inside of is not a tag (a browser drops it too), and nothing follows it.
  if not read.ok?
    return Piece(html: "", open: open, next: n)
  end

  # Safe: `ok?` was checked above.
  tag = read.unwrap!
  if tag.closing
    return close_piece(tag, open)
  end

  return open_piece(cs, n, tag, open)
end

def open_piece(cs: List[String], n: Int, tag: Tag, open: List[String]) -> Piece
  name = tag.name
  if DROPPED_WITH_CONTENT.include?(name)
    return Piece(html: "", open: open, next: raw_text_end(cs, n, tag.next, name))
  end

  if not ALLOWED_TAGS.include?(name)
    return Piece(html: "", open: open, next: tag.next)
  end

  if name == "br"
    return Piece(html: "<br>", open: open, next: tag.next)
  end

  if open.size >= MAX_DEPTH
    return Piece(html: "", open: open, next: tag.next)
  end

  if name == "a"
    return link_piece(tag, open)
  end

  return Piece(html: "<#{name}>", open: open.push(name), next: tag.next)
end

# A link opens only with a good address. One link inside another closes the first, as in a browser.
def link_piece(tag: Tag, open: List[String]) -> Piece
  url = safe_href(tag.href.unwrap_or(""))
  if url.none?
    return Piece(html: "", open: open, next: tag.next)
  end

  link = "<a href=\"#{HTML.escape(url.unwrap!)}\" rel=\"#{LINK_REL}\">"
  inner = position_of(open, "a")
  if inner < 0
    return Piece(html: link, open: open.push("a"), next: tag.next)
  end

  return Piece(html: "#{closing_tags(open, inner)}#{link}", open: open.take(inner).push("a"), next: tag.next)
end

# An end tag closes what it names and what was opened inside it; one that names nothing open goes.
def close_piece(tag: Tag, open: List[String]) -> Piece
  inner = position_of(open, tag.name)
  if inner < 0
    return Piece(html: "", open: open, next: tag.next)
  end

  return Piece(html: closing_tags(open, inner), open: open.take(inner), next: tag.next)
end

# The place of the innermost open `name`, or -1.
def position_of(open: List[String], name: String) -> Int
  k = open.size - 1
  while k >= 0 and open[k] != name
    k -= 1
  end

  return k
end

# The end tags of `open` from the innermost down to the one at `keep`.
def closing_tags(open: List[String], keep: Int) -> String
  parts: List[String] = []
  k = open.size - 1
  while k >= keep
    parts = parts.push("</#{open[k]}>")
    k -= 1
  end

  return parts.join("")
end

# Reads the tag whose `<` is at `start` (a letter or `/` and a letter follows), the way the HTML tokenizer does: a
# quoted value may hold `>`, and the first `href` wins. An error is a tag that the text ends inside of.
def read_tag(cs: List[String], n: Int, start: Int) -> Result[Tag]
  i = start + 1
  closing = at(cs, n, i) == "/"
  if closing
    i += 1
  end

  name = take_until(cs, n, i, NAME_END)
  i = name.next
  href: Optional[String] = none
  i = skip(cs, n, i, BETWEEN_ATTRIBUTES)
  while i < n
    if cs[i] == ">"
      return ok(Tag(name: name.text.downcase, closing: closing, href: href, next: i + 1))
    end

    # The first character is always part of the name, even an `=`.
    attribute_start = i
    attribute = take_until(cs, n, i + 1, ATTRIBUTE_END)
    i = skip(cs, n, attribute.next, WHITESPACE)
    value = ""
    if at(cs, n, i) == "="
      read = try read_value(cs, n, skip(cs, n, i + 1, WHITESPACE))
      value = read.text
      i = read.next
    end

    if href.none? and "#{cs[attribute_start]}#{attribute.text}".downcase == "href"
      href = some(value)
    end

    i = skip(cs, n, i, BETWEEN_ATTRIBUTES)
  end

  return error("tag not closed")
end

# The text of the value that starts at `start`, quoted or not, and the place after it. An error is a quote that the
# text ends before it closes.
def read_value(cs: List[String], n: Int, start: Int) -> Result[Run]
  quote = at(cs, n, start)
  if quote == "\"" or quote == "'"
    stops = DOUBLE_QUOTE
    if quote == "'"
      stops = SINGLE_QUOTE
    end

    run = take_until(cs, n, start + 1, stops)
    if run.next >= n
      return error("value not closed")
    end

    return ok(Run(text: run.text, next: run.next + 1))
  end

  return ok(take_until(cs, n, start, UNQUOTED_END))
end

# The address of a link, ready to write, or none when it is not one to follow. A browser reads the value of an
# attribute with its entities decoded, and drops tabs and line breaks anywhere in an address, so the check is on that
# text; the text that is written is that text escaped again, so a browser reads back exactly what was checked.
def safe_href(raw: String) -> Optional[String]
  url = HTML.unescape(raw).replace("\t", "").replace("\n", "").replace("\r", "").strip
  if url.empty? or has_control?(url) or not scheme_allowed?(url)
    return none
  end

  return some(url)
end

def has_control?(text: String) -> Bool
  return text.split("").any? do |c| c.code < 32 or c.code == 127 end
end

# An address with no scheme is relative; with one (a colon before any `/`, `?` or `#`) it must be on the list. A
# colon-prefix that is not a real scheme is refused too, which is stricter than a browser and costs nothing.
def scheme_allowed?(url: String) -> Bool
  cs = url.split("")
  n = cs.size
  head = take_until(cs, n, 0, URL_DELIMITERS)
  if at(cs, n, head.next) != ":"
    return true
  end

  return ALLOWED_SCHEMES.include?(head.text.downcase)
end

# The place after the entity at `start` (an `&`) when it is a name or a number then `;`, which is text that a browser
# shows as one character and which is safe to pass on, else -1.
def entity_end(cs: List[String], n: Int, start: Int) -> Int
  i = start + 1
  digits = ENTITY_CHARS
  if at(cs, n, i) == "#"
    i += 1
    digits = DIGITS
    if at(cs, n, i) == "x" or at(cs, n, i) == "X"
      i += 1
      digits = HEX_DIGITS
    end
  end

  first = i
  while i < n and i - first < MAX_ENTITY and digits.include?(cs[i])
    i += 1
  end

  if i > first and at(cs, n, i) == ";"
    return i + 1
  end

  return -1
end

# The place after a comment whose `<!--` ends before `start`. `<!-->` and `<!--->` are whole comments, and `--!>`
# ends one like `-->` does; a comment that never ends takes the rest of the text.
def comment_end(cs: List[String], n: Int, start: Int) -> Int
  if at(cs, n, start) == ">"
    return start + 1
  end

  if at(cs, n, start) == "-" and at(cs, n, start + 1) == ">"
    return start + 2
  end

  j = start
  while j < n
    if cs[j] == "-" and at(cs, n, j + 1) == "-"
      if at(cs, n, j + 2) == ">"
        return j + 3
      end

      if at(cs, n, j + 2) == "!" and at(cs, n, j + 3) == ">"
        return j + 4
      end
    end

    j += 1
  end

  return n
end

# The place after the next `>`, for `<!DOCTYPE>`, `<?xml ?>`, `<![CDATA[` and `</ x>`, which a browser reads
# as comments.
def bogus_end(cs: List[String], n: Int, start: Int) -> Int
  j = start
  while j < n and cs[j] != ">"
    j += 1
  end

  return j + 1
end

# The place after the end tag of `name` that closes a script or its kind, or the end of the text.
def raw_text_end(cs: List[String], n: Int, start: Int, name: String) -> Int
  letters = name.split("")
  j = start
  while j < n
    if cs[j] == "<" and at(cs, n, j + 1) == "/" and spells?(cs, n, j + 2, letters)
      if AFTER_END_NAME.include?(at(cs, n, j + 2 + letters.size))
        closer = read_tag(cs, n, j)
        if closer.ok?
          return closer.unwrap!.next
        end

        return n
      end
    end

    j += 1
  end

  return n
end

def spells?(cs: List[String], n: Int, start: Int, letters: List[String]) -> Bool
  k = 0
  while k < letters.size
    if at(cs, n, start + k).downcase != letters[k]
      return false
    end

    k += 1
  end

  return true
end

# The text from `start` up to the first character in `stops`, or the end, and the place where it stopped.
def take_until(cs: List[String], n: Int, start: Int, stops: Set[String]) -> Run
  parts: List[String] = []
  i = start
  while i < n and not stops.include?(cs[i])
    parts = parts.push(cs[i])
    i += 1
  end

  return Run(text: parts.join(""), next: i)
end

def skip(cs: List[String], n: Int, start: Int, skipped: Set[String]) -> Int
  i = start
  while i < n and skipped.include?(cs[i])
    i += 1
  end

  return i
end

# The character at `i`, or "" past the end, so a look ahead needs no bounds check.
def at(cs: List[String], n: Int, i: Int) -> String
  if i < n
    return cs[i]
  end

  return ""
end

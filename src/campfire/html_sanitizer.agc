## An allowlist sanitizer for the HTML of a stored message body (Action Text, as the Rails Campfire wrote it), so the
## body can be shown with `<%== %>`. `sanitize` reads the text once and writes a new text that is made only of what
## this file writes: the tags of `ALLOWED_TAGS` with no attribute (a link has `href` and `rel`, a `pre` may have
## `data-language`, the language of a code block, nothing else), text
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
## - fewer tags: Rails also lets through dl, dt, dd, abbr, acronym, address, big, dfn, ins, kbd, samp, small, time,
##   tt, var, figure and figcaption; each is one more word in `ALLOWED_TAGS`.
## - a tag that is not allowed: Rails drops the element with its text; here the tag goes and its text stays.
## - fewer attributes: Rails keeps `class`, `title`, `alt`, `src`, `width`, `height`, `data-language` and a few more;
##   here only `href` of a link survives (and `rel`, which is written, not copied) and `data-language`, which Rails
##   keeps on any tag and the editor writes on a `pre`, so only there and only as a short name (`ruby`, `c++`).
## - schemes: Loofah's list has more (ftp, tel, ...); here only http, https and mailto, and a relative address.
## - `<a>` with no usable `href` is dropped (its text stays); Rails keeps the tag without the attribute.
## - tags that are mis-nested are closed in order; Rails (Nokogiri) rebuilds the tree the way a browser does. Only its
##   common implied end tags are done here: a new `li`, `tr`, `td` or `th` ends the open one, and a `p` ends at a
##   block tag.

import HTML from "std/html"

# The tags that are kept, with the attributes dropped. `br` and `hr` are void, `a` is handled apart.
ALLOWED_TAG_NAMES = [
  "p",
  "br",
  "hr",
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
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "u",
  "mark",
  "sub",
  "sup",
  "span",
  "cite",
  "a",
  "table",
  "thead",
  "tbody",
  "tfoot",
  "tr",
  "th",
  "td",
]

ALLOWED_TAGS = Set.new(ALLOWED_TAG_NAMES)

# The allowed tags that `sanitize` writes with no more than the name; `a` has the address.
PLAIN_TAGS = Set.new(ALLOWED_TAG_NAMES.select do |name| name != "a" end)

# The characters of the language of a code block, and its longest name.
LANGUAGE_CHARS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+#.-".split(""))
MAX_LANGUAGE = 32

# What lies between `<` and `>` of an end tag with no attribute: `/p`.
END_TAGS = Set.new(ALLOWED_TAG_NAMES.map do |name| "/#{name}" end)

VOID_TAGS = Set.new(["br", "hr"])

# The implied end tags of HTML, in the common cases. A start tag ends the innermost open tag of a kind (the targets)
# and what lies inside it, as long as no wall comes first: a wall starts a context of its own, so a `li` in a nested
# `ul` does not end the `li` outside it. What is closed here is what the output closes, so sanitizing it again changes
# nothing.
LIST_ITEMS = Set.new(["li"])
PARAGRAPHS = Set.new(["p"])
TABLE_ROWS = Set.new(["tr"])
TABLE_CELLS = Set.new(["td", "th"])
LIST_ITEM_WALLS = Set.new(["ul", "ol", "blockquote", "pre", "table", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6"])
PARAGRAPH_WALLS = Set.new(["table", "td", "th"])
TABLE_ROW_WALLS = Set.new(["table"])
TABLE_CELL_WALLS = Set.new(["tr", "table"])

# The tags that end an open `p` when they start.
PARAGRAPH_ENDERS = [
  "p",
  "div",
  "blockquote",
  "ul",
  "ol",
  "li",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "pre",
  "table",
  "hr",
]

ENDS_PARAGRAPH = Set.new(PARAGRAPH_ENDERS)

# The tags that end an open tag when they start, whichever it is.
AUTO_CLOSING = Set.new(PARAGRAPH_ENDERS.concat(["tr", "td", "th"]))

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

# The tags where `plain_text` breaks the line: the ones that end a block, and `br`.
BREAKING_TAGS = Set.new([
  "p",
  "br",
  "hr",
  "div",
  "pre",
  "blockquote",
  "ul",
  "ol",
  "li",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "table",
  "tr",
  "th",
  "td",
])

ALLOWED_SCHEMES = Set.new(["http", "https", "mailto"])

# A link is the one tag with a rel: the page that it opens gets no handle on this one.
LINK_REL = "noopener noreferrer"

# The depth of open tags. A message is a few levels deep; the cap keeps the cost of closing a tag from growing with
# the input, and a tag past it is dropped.
MAX_DEPTH = 64

# How many characters `find_from` looks at in one `index_of`.
SEARCH_WINDOW = 256

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
  language: Optional[String]
  next: Int
end

# The HTML to write and the open tags after the tags that a start tag ends.
struct Closed
  html: String
  open: List[String]
end

# The text that `markup` reads: the characters, which are the places that it counts in, and the text itself, which a
# run is cut from in one `slice` when `ascii` (a slice of other text costs the length up to where it starts, so
# many of them would be quadratic).
struct Text
  source: String
  chars: List[String]
  size: Int
  ascii: Bool
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
  source = html
  if html.include?(NUL)
    source = html.replace(NUL, "")
  end

  # Every part but the first starts right after a `<`, so the text is read a part at a time: a tag with no attribute
  # (`p`, `/p`) is its part up to the first `>`, and the rest of the part is text. What is not that simple (an
  # attribute, a comment, a script, a tag that goes on in the next part) is read by `markup` over the characters.
  parts = source.split("<")
  size = parts.size
  out: List[String] = [escape_text(parts[0])]
  open: List[String] = []
  # The characters of the whole text, only built when `markup` needs them.
  text = Text(source: source, chars: [], size: 0, ascii: true)
  # Part `mark` starts at the place `mark_start` of the text; they only move forward, so finding a place costs one
  # pass over all the parts, not one for each.
  mark = 0
  mark_start = 0
  k = 1
  while k < size
    part = parts[k]
    stop = part.index_of(">").unwrap_or(-1)
    head = ""
    if stop >= 0
      head = part.slice(0, stop).downcase
    end

    if PLAIN_TAGS.include?(head)
      piece = start_piece(head, open, 0, "")
      out = out.push(piece.html)
      open = piece.open
      if stop + 1 < part.length
        out = out.push(escape_text(part.slice(stop + 1, part.length - stop - 1)))
      end

      k += 1
    elsif END_TAGS.include?(head)
      piece = close_piece(head.slice(1, head.length - 1), open, 0)
      out = out.push(piece.html)
      open = piece.open
      if stop + 1 < part.length
        out = out.push(escape_text(part.slice(stop + 1, part.length - stop - 1)))
      end

      k += 1
    elsif not markup_start?(part)
      # A lone `<`.
      out = out.push("&lt;")
      out = out.push(escape_text(part))
      k += 1
    else
      # `size` is 0 only until the characters are read: a text with a `<` is never empty.
      if text.size == 0
        text = read_text(source)
      end

      while mark < k
        mark_start += parts[mark].length + 1
        mark += 1
      end

      marked = markup(text, mark_start - 1, open)
      out = out.push(marked.html)
      open = marked.open
      # `markup` ends inside a part or at its end (the next `<`), and what is left of that part is text.
      j = k
      j_start = mark_start
      while j < size - 1 and marked.next > j_start + parts[j].length
        j_start += parts[j].length + 1
        j += 1
      end

      # `markup` may report one place past the end of the text.
      rest = (marked.next - j_start).clamp(0, parts[j].length)
      out = out.push(escape_text(parts[j].slice(rest, parts[j].length - rest)))
      mark = j
      mark_start = j_start
      k = j + 1
    end
  end

  return out.push(closing_tags(open, 0)).join("")
end

## The HTML of a plain text, as a body that `sanitize` leaves as it is: `&`, `<`, `>` and the quotes escaped, and a new
## line made a `<br>`, since HTML shows a new line as a space.
export def from_text(text: String) -> String
  return HTML.escape(text).replace("\r\n", "\n").replace("\n", "<br>")
end

## The text that an edit form shows for a clean body. A body that is plain text as `from_text` wrote it (no tag but
## `<br>`) gives that text back exactly, blank lines included, so saving the form again changes nothing. Any other markup
## (a body that Rails wrote) gives `plain_text_of_clean`, which keeps no blank line and no formatting.
export def text_of_clean(clean: String) -> String
  if clean.replace("<br>", "").include?("<")
    return plain_text_of_clean(clean)
  end

  return HTML.unescape(clean.replace("<br>", "\n"))
end

## The text of the HTML `html` without its markup, as the search index keeps it (Action Text's `to_plain_text` does the
## same for Rails): the text of the sanitized body, the entities read back (`&amp;` is `&`), a line break at the end of
## a block and at a `<br>`, and no empty line. It reads what `sanitize` wrote, so a tag in it is a name, maybe the
## attributes of a link, then the first `>`: a `>` in a value is written as `&gt;`.
export def plain_text(html: String) -> String
  return plain_text_of_clean(sanitize(html))
end

## `plain_text` of a body that `sanitize` has cleaned already, for the caller that has the clean text and so does not
## sanitize it a second time.
export def plain_text_of_clean(clean: String) -> String
  text = read_text(clean)
  cs = text.chars
  n = text.size
  out: List[String] = []
  i = 0
  while i < n
    if cs[i] != "<"
      out = out.push(cs[i])
      i += 1
    else
      close = i + 1
      if at(cs, n, close) == "/"
        close += 1
      end

      name = take_until(text, close, Set.new([">", " "]))
      if BREAKING_TAGS.include?(name.text)
        out = out.push("\n")
      end

      i = bogus_end(cs, n, i)
    end
  end

  lines = HTML.unescape(out.join("")).split("\n").map do |line| line.strip end
  return lines.select do |line| not line.empty? end.join("\n")
end

# The first character of what follows a `<` makes it markup (a tag, a comment) and not a lone `<` that is text.
def markup_start?(part: String) -> Bool
  if part.empty?
    return false
  end

  first = part.slice(0, 1)
  return first == "!" or first == "?" or first == "/" or LETTERS.include?(first)
end

# `text` (which has no `<`) with `>` escaped, `&` escaped unless it starts an entity.
def escape_text(text: String) -> String
  if not text.include?("&")
    return text.replace(">", "&gt;")
  end

  pieces = text.split("&")
  out = [pieces[0].replace(">", "&gt;")]
  for piece in pieces.drop(1)
    chars = "&#{piece}".split("")
    stop = entity_end(chars, chars.size, 0)
    if stop < 0
      out = out.push("&amp;#{piece.replace(">", "&gt;")}")
    else
      # `stop` counts the `&` too: the entity is `stop - 1` characters of the piece, and the text goes on after it.
      after = piece.slice(stop - 1, piece.length - stop + 1)
      out = out.push("&#{piece.slice(0, stop - 1)}#{after.replace(">", "&gt;")}")
    end
  end

  return out.join("")
end

# Handles the `<` at `start`: a tag, a comment, or a lone `<` that is text.
def markup(text: Text, start: Int, open: List[String]) -> Piece
  cs = text.chars
  n = text.size
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
    return tag_piece(text, start, open)
  end

  return Piece(html: "&lt;", open: open, next: start + 1)
end

def tag_piece(text: Text, start: Int, open: List[String]) -> Piece
  read = read_tag(text, start)
  # A tag that the text ends inside of is not a tag (a browser drops it too), and nothing follows it.
  if not read.ok?
    return Piece(html: "", open: open, next: text.size)
  end

  # Safe: `ok?` was checked above.
  tag = read.unwrap!
  if tag.closing
    return close_piece(tag.name, open, tag.next)
  end

  return open_piece(text, tag, open)
end

def open_piece(text: Text, tag: Tag, open: List[String]) -> Piece
  name = tag.name
  if DROPPED_WITH_CONTENT.include?(name)
    return Piece(html: "", open: open, next: raw_text_end(text, tag.next, name))
  end

  if not ALLOWED_TAGS.include?(name)
    return Piece(html: "", open: open, next: tag.next)
  end

  if name == "a"
    # No end tag is implied for a link, and the cap comes first.
    if open.size >= MAX_DEPTH
      return Piece(html: "", open: open, next: tag.next)
    end

    return link_piece(tag, open)
  end

  return start_piece(name, open, tag.next, language_of(name, tag))
end

# The `data-language` that is written on a tag: a short name, on a `pre` only; "" for none.
def language_of(name: String, tag: Tag) -> String
  language = tag.language.unwrap_or("")
  if name != "pre" or language.empty? or language.length > MAX_LANGUAGE
    return ""
  end

  if language.split("").all? do |c| LANGUAGE_CHARS.include?(c) end
    return language
  end

  return ""
end

# A start tag of `PLAIN_TAGS`; `next` is where the input goes on after it. `language` is the `data-language` of a `pre`
# ("" for none), checked by `language_of`, so it is written as it is.
def start_piece(name: String, open: List[String], next: Int, language: String) -> Piece
  ended = ""
  stack = open
  # With nothing open, no tag ends.
  if stack.size > 0 and AUTO_CLOSING.include?(name)
    closed = auto_close(stack, name)
    ended = closed.html
    stack = closed.open
  end

  if VOID_TAGS.include?(name)
    return Piece(html: "#{ended}<#{name}>", open: stack, next: next)
  end

  tag = "<#{name}>"
  if not language.empty?
    tag = "<#{name} data-language=\"#{language}\">"
  end

  # The cap is checked after the end tags above, which make room.
  if stack.size >= MAX_DEPTH
    return Piece(html: ended, open: stack, next: next)
  end

  return Piece(html: "#{ended}#{tag}", open: stack.push(name), next: next)
end

# The end tags that the start tag `name` implies. The cost is bounded by MAX_DEPTH, as the stack is.
def auto_close(open: List[String], name: String) -> Closed
  closed = Closed(html: "", open: open)
  if name == "li"
    closed = end_open(closed, LIST_ITEMS, LIST_ITEM_WALLS)
  elsif name == "tr"
    closed = end_open(closed, TABLE_ROWS, TABLE_ROW_WALLS)
  elsif name == "td" or name == "th"
    closed = end_open(closed, TABLE_CELLS, TABLE_CELL_WALLS)
  end

  if ENDS_PARAGRAPH.include?(name)
    closed = end_open(closed, PARAGRAPHS, PARAGRAPH_WALLS)
  end

  return closed
end

# Ends the innermost open tag of `targets`, and what is inside it, unless a wall comes first.
def end_open(closed: Closed, targets: Set[String], walls: Set[String]) -> Closed
  open = closed.open
  k = open.size - 1
  while k >= 0 and not targets.include?(open[k])
    if walls.include?(open[k])
      return closed
    end

    k -= 1
  end

  if k < 0
    return closed
  end

  return Closed(html: "#{closed.html}#{closing_tags(open, k)}", open: open.take(k))
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
def close_piece(name: String, open: List[String], next: Int) -> Piece
  top = open.size - 1
  # The usual end tag closes the innermost one.
  if top >= 0 and open[top] == name
    return Piece(html: "</#{name}>", open: open.take(top), next: next)
  end

  inner = position_of(open, name)
  if inner < 0
    return Piece(html: "", open: open, next: next)
  end

  return Piece(html: closing_tags(open, inner), open: open.take(inner), next: next)
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
  k = open.size - 1
  if k < keep
    return ""
  end

  if k == keep
    return "</#{open[k]}>"
  end

  parts: List[String] = []
  while k >= keep
    parts = parts.push("</#{open[k]}>")
    k -= 1
  end

  return parts.join("")
end

# Reads the tag whose `<` is at `start` (a letter or `/` and a letter follows), the way the HTML tokenizer does: a
# quoted value may hold `>`, and the first `href` wins. An error is a tag that the text ends inside of.
def read_tag(text: Text, start: Int) -> Result[Tag]
  cs = text.chars
  n = text.size
  i = start + 1
  closing = at(cs, n, i) == "/"
  if closing
    i += 1
  end

  name = take_until(text, i, NAME_END)
  i = name.next
  href: Optional[String] = none
  language: Optional[String] = none
  i = skip(cs, n, i, BETWEEN_ATTRIBUTES)
  while i < n
    if cs[i] == ">"
      return ok(Tag(name: name.text.downcase, closing: closing, href: href, language: language, next: i + 1))
    end

    # The first character is always part of the name, even an `=`.
    attribute_start = i
    attribute = take_until(text, i + 1, ATTRIBUTE_END)
    i = skip(cs, n, attribute.next, WHITESPACE)
    value = ""
    if at(cs, n, i) == "="
      read = try read_value(text, skip(cs, n, i + 1, WHITESPACE))
      value = read.text
      i = read.next
    end

    attribute_name = "#{cs[attribute_start]}#{attribute.text}".downcase
    if href.none? and attribute_name == "href"
      href = some(value)
    elsif language.none? and attribute_name == "data-language"
      language = some(value)
    end

    i = skip(cs, n, i, BETWEEN_ATTRIBUTES)
  end

  return error("tag not closed")
end

# The text of the value that starts at `start`, quoted or not, and the place after it. An error is a quote that the
# text ends before it closes.
def read_value(text: Text, start: Int) -> Result[Run]
  n = text.size
  quote = at(text.chars, n, start)
  if quote == "\"" or quote == "'"
    stop = find_from(text, start + 1, quote)
    if stop >= n
      return error("value not closed")
    end

    return ok(Run(text: run_of(text, start + 1, stop), next: stop + 1))
  end

  return ok(take_until(text, start, UNQUOTED_END))
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
  text = read_text(url)
  cs = text.chars
  n = text.size
  head = take_until(text, 0, URL_DELIMITERS)
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
def raw_text_end(text: Text, start: Int, name: String) -> Int
  cs = text.chars
  n = text.size
  letters = name.split("")
  j = start
  while j < n
    if cs[j] == "<" and at(cs, n, j + 1) == "/" and spells?(cs, n, j + 2, letters)
      if AFTER_END_NAME.include?(at(cs, n, j + 2 + letters.size))
        closer = read_tag(text, j)
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
def take_until(text: Text, start: Int, stops: Set[String]) -> Run
  cs = text.chars
  n = text.size
  i = start
  while i < n and not stops.include?(cs[i])
    i += 1
  end

  return Run(text: run_of(text, start, i), next: i)
end

# The place of the first `needle` from `start` on, or the end of the text. In ASCII text it looks at a window of
# characters at a time with `index_of`, which cannot start in the middle of a text, so a long run is a few builtin
# calls.
def find_from(text: Text, start: Int, needle: String) -> Int
  n = text.size
  i = start
  if not text.ascii
    cs = text.chars
    while i < n and cs[i] != needle
      i += 1
    end

    return i
  end

  while i < n
    width = (n - i).clamp(1, SEARCH_WINDOW)
    found = text.source.slice(i, width).index_of(needle)
    if found.some?
      return i + found.unwrap!
    end

    i += width
  end

  return n
end

# The text from the place `from` up to the place `to`.
def run_of(text: Text, from: Int, to: Int) -> String
  if text.ascii
    return text.source.slice(from, to - from)
  end

  cs = text.chars
  pieces: List[String] = []
  i = from
  while i < to
    pieces = pieces.push(cs[i])
    i += 1
  end

  return pieces.join("")
end

# The characters of `source`, once, so that the places of a reader count in them.
def read_text(source: String) -> Text
  chars = source.split("")
  return Text(source: source, chars: chars, size: chars.size, ascii: source.bytesize == chars.size)
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

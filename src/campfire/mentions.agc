## The mentions of people in a message (Rails' `User::Mentionable` and `Message::Mentionee`). A mention is the element
## that `HtmlSanitizer.mention_open` writes, with the GlobalID of the user and the text `@NAME` (Rails' plain text of a
## mention), so the search index and the webhooks read `@NAME`. Rails names the user with a signed GlobalID (`sgid`),
## which needs `SECRET_KEY_BASE`; this app writes the GlobalID itself, and `Rooms.post` keeps only the mentions of the
## active people of the room. Pure: the caller looks the people up.

import HTML from "std/html"
import HtmlSanitizer from "html_sanitizer"

## A person that a message may mention: an active person of its room.
struct Person
  id: Int
  name: String
end

## The markup of a mention of the person `id` called `name`.
def markup(id: Int, name: String) -> String
  "#{HtmlSanitizer.mention_open(id)}@#{HTML.escape(name)}#{HtmlSanitizer.MENTION_CLOSE}"
end

## The GlobalID of the user `id`, which a mention carries.
def gid(id: Int) -> String = "#{HtmlSanitizer.MENTION_GID}#{id}"

## The people that the mentions of the clean body name, each once, in the order of the body.
def ids(clean: String) -> List[Int]
  found: List[Int] = []
  for piece in clean.split(HtmlSanitizer.MENTION_PREFIX).drop(1)
    id = piece.split("\"")[0].to_i.unwrap_or(0)
    if id > 0 and not found.include?(id)
      found = found.push(id)
    end
  end

  found
end

## The clean body with its mentions checked against `people`: a mention of one of them says `@NAME` with their name of
## now, and a mention of anybody else is left as its text, without the element.
def settle(clean: String, people: List[Person]) -> String
  pieces = clean.split(HtmlSanitizer.MENTION_PREFIX)
  return clean if pieces.size < 2

  names = name_map(people)
  out = [pieces[0]]
  for piece in pieces.drop(1)
    start = piece.index_of("\">").unwrap_or(0)
    id = piece.slice(0, start).to_i.unwrap_or(0)
    inner = rest(piece, start + 2)
    close = inner.index_of(HtmlSanitizer.MENTION_CLOSE).unwrap_or(inner.length)
    after = rest(inner, close + HtmlSanitizer.MENTION_CLOSE.length)
    name = names.get(id)
    case name
      some(n) -> out = out.push("#{markup(id, n)}#{after}")
      none -> out = out.push("#{inner.slice(0, close)}#{after}")
    end
  end

  out.join("")
end

## The body that `HtmlSanitizer.from_text` made of a typed text, with each `@NAME` of one of `people` made a mention:
## the `@` starts the text or follows anything but a letter, a digit or `_`, and the name is not followed by one; the
## longest name wins (`@Ana Lopez` over `@Ana`).
def link(html: String, people: List[Person]) -> String
  parts = html.split("@")
  return html if parts.size < 2 or people.empty?

  named_people = people.select do |p| not p.name.empty? end
  longest_first = named_people.sort_by do |p| -p.name.length end
  escaped = longest_first.map do |p| Escaped(id: p.id, name: p.name, html: HTML.escape(p.name)) end
  out = [parts[0]]
  previous = parts[0]
  for part in parts.drop(1)
    found: Optional[Escaped] = none
    if not word_end?(previous)
      found = named(part, escaped)
    end

    case found
      some(person) -> out = out.push("#{markup(person.id, person.name)}#{rest(part, person.html.length)}")
      none -> out = out.push("@#{part}")
    end

    previous = part
  end

  out.join("")
end

private

# A letter, a digit or `_`: what may not touch a mention on either side.
WORD = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

struct Escaped
  id: Int
  name: String
  html: String
end

# The text from the place `at` on, "" past its end.
def rest(text: String, at: Int) -> String
  return "" if at >= text.length

  text.slice(at, text.length - at)
end

def name_map(people: List[Person]) -> Map[Int, String]
  start: Map[Int, String] = {}
  people.reduce(start) do |names, p| names.put(p.id, p.name) end
end

def word_end?(text: String) -> Bool = not text.empty? and WORD.include?(text.slice(text.length - 1, 1))

def named(part: String, people: List[Escaped]) -> Optional[Escaped]
  for p in people
    if part.start_with?(p.html) and not (part.length > p.html.length and WORD.include?(part.slice(p.html.length, 1)))
      return some(p)
    end
  end

  none
end

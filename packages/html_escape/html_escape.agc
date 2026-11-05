## HTML escaping in C: `escape` gives what `HTML.escape` of `std/html` gives (and so `Bond.escape`), in one pass over
## the text instead of five.

import HTML from "std/html"

NUL = String.from_code(0)

## `text` with `&`, `<`, `>`, `"` and `'` replaced by `&amp;`, `&lt;`, `&gt;`, `&quot;` and `&#39;`.
export def escape(text: String) -> String
  # A NUL in a `C.String` stops the program, so such a text takes std/html, whose output is the same.
  if text.include?(NUL)
    return HTML.escape(text)
  end

  return campfire_html_escape(text)
end

extern "html_escape"
  def campfire_html_escape(text: C.String) -> C.String
end

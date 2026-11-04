import HtmlSanitizer from "../src/campfire/html_sanitizer"

NUL = String.from_code(0)
LINK_REL = "rel=\"noopener noreferrer\""

# The names that the output may open or close; the one tag with attributes is the link.
OUTPUT_TAGS = Set.new([
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

ATTACHMENT = (
  "<action-text-attachment sgid=\"abc\"><figure><img src=\"/x.png\">" +
  "<figcaption>cap</figcaption></figure></action-text-attachment>"
)

struct Case
  input: String
  want: String
end

# The bodies of Action Text and what the people of a chat write: markup that stays as it is, but for its attributes.
def action_text_cases() -> List[Case]
  return [
    Case(input: "plain text", want: "plain text"),
    Case(input: "<p>Hello <strong>world</strong></p>", want: "<p>Hello <strong>world</strong></p>"),
    Case(
      input: "<div class=\"trix-content\">\n  <div>Hi <em>team</em>,<br>lunch at <b>noon</b>?<br /></div>\n</div>\n",
      want: "<div>\n  <div>Hi <em>team</em>,<br>lunch at <b>noon</b>?<br></div>\n</div>\n",
    ),
    Case(input: "<ul><li>one</li><li>two</li></ul>", want: "<ul><li>one</li><li>two</li></ul>"),
    Case(input: "<ol><li>one <i>and</i> two</li></ol>", want: "<ol><li>one <i>and</i> two</li></ol>"),
    Case(input: "<h1>Title</h1><s>old</s> <del>older</del>", want: "<h1>Title</h1><s>old</s> <del>older</del>"),
    Case(input: "<blockquote>quoted</blockquote>", want: "<blockquote>quoted</blockquote>"),
    Case(
      input: "<pre data-language=\"ruby\">puts \"a\" &lt; 1\n  x</pre>a <code>b &amp; c</code>",
      want: "<pre>puts \"a\" &lt; 1\n  x</pre>a <code>b &amp; c</code>",
    ),
    Case(
      input: "<table><thead><tr><th>a</th></tr></thead><tbody><tr><td colspan=\"2\">b</td></tr></tbody></table>",
      want: "<table><thead><tr><th>a</th></tr></thead><tbody><tr><td>b</td></tr></tbody></table>",
    ),
    Case(
      input: "<a href=\"https://example.com/a?b=1&amp;c=2\" target=\"_blank\">link</a>",
      want: "<a href=\"https://example.com/a?b=1&amp;c=2\" #{LINK_REL}>link</a>",
    ),
    Case(
      input: "<a href=\"mailto:ana@example.com\">mail</a> <A HREF=http://example.com>up</A>",
      want: (
        "<a href=\"mailto:ana@example.com\" #{LINK_REL}>mail</a> <a href=\"http://example.com\" #{LINK_REL}>up</a>"
      ),
    ),
    Case(
      input: "<a href=\"/rooms/2\">a</a><a href=\"#top\">b</a><a href=\"?q=1\">c</a>",
      want: (
        "<a href=\"/rooms/2\" #{LINK_REL}>a</a><a href=\"#top\" #{LINK_REL}>b</a><a href=\"?q=1\" #{LINK_REL}>c</a>"
      ),
    ),
    Case(input: "héllo ☕ <b>ñ</b>", want: "héllo ☕ <b>ñ</b>"),
    Case(input: ATTACHMENT, want: "cap"),
    Case(input: "<p>a</p><img src=\"/x.png\"><video src=\"v.mp4\"></video><p>b</p>", want: "<p>a</p><p>b</p>"),
  ]
end

# Text that is not markup is escaped, and what is left open or mis-nested is closed.
def well_formed_cases() -> List[Case]
  return [
    Case(input: "a < b > c & d", want: "a &lt; b &gt; c &amp; d"),
    Case(input: "1 <2 and 3< 4 <", want: "1 &lt;2 and 3&lt; 4 &lt;"),
    Case(input: "&amp; &lt; &gt; &quot; &#39; &#x27; &nbsp;", want: "&amp; &lt; &gt; &quot; &#39; &#x27; &nbsp;"),
    Case(input: "&bogus &#; &#xZZ; &; &lt", want: "&amp;bogus &amp;#; &amp;#xZZ; &amp;; &amp;lt"),
    Case(input: "<b>bold <i>both</b> italic</i> end", want: "<b>bold <i>both</i></b> italic end"),
    Case(input: "<p><b>open", want: "<p><b>open</b></p>"),
    Case(input: "</b>x</p></div>", want: "x"),
    Case(input: "<p>a</p></p>b", want: "<p>a</p>b"),
    Case(input: "<br/><BR><br />a</br>", want: "<br><br><br>a"),
    Case(input: "<ul><li>a<li>b</ul>", want: "<ul><li>a<li>b</li></li></ul>"),
    Case(
      input: "<a href=\"http://a\">one<a href=\"http://b\">two</a></a>",
      want: "<a href=\"http://a\" #{LINK_REL}>one</a><a href=\"http://b\" #{LINK_REL}>two</a>",
    ),
    Case(input: "<a href=\"http://x\">text", want: "<a href=\"http://x\" #{LINK_REL}>text</a>"),
    Case(input: "<p>cut <a href=\"http://x", want: "<p>cut </p>"),
    Case(input: "<P ID=1 Class='x'>Up</P>", want: "<p>Up</p>"),
    Case(input: "<p/>x", want: "<p>x</p>"),
  ]
end

# What is dropped with what is in it, and what is dropped and leaves its text.
def dropped_cases() -> List[Case]
  return [
    Case(input: "<script>alert(1)</script>x", want: "x"),
    Case(input: "a<style>p { color: red }</style>b", want: "ab"),
    Case(input: "<SCRIPT SRC=http://example.com/x.js></SCRIPT>ok", want: "ok"),
    Case(input: "<script>var a = \"<b>\";</script>ok", want: "ok"),
    Case(input: "<script>\"</scriptx>\"</script>ok", want: "ok"),
    Case(input: "<script>a</script foo=\"bar\">ok", want: "ok"),
    Case(input: "<script>a</SCRIPT\n>ok", want: "ok"),
    Case(input: "ok<script>alert(1)", want: "ok"),
    Case(input: "<style><!--</style><script>alert(1)</script>-->", want: "--&gt;"),
    Case(input: "<iframe src=\"javascript:alert(1)\"></iframe>x", want: "x"),
    Case(input: "<textarea><b>x</b></textarea><title>t</title>y", want: "y"),
    Case(input: "<noscript><p title=\"</noscript><img src=x onerror=alert(1)>\">", want: "\"&gt;"),
    Case(input: "<svg onload=alert(1)>t</svg>u", want: "u"),
    Case(input: "<svg><script>alert(1)</script></svg>u", want: "u"),
    Case(input: "<math><mtext><style><img src=x onerror=alert(1)></style></mtext></math>u", want: "u"),
    Case(input: "<object data=\"x.swf\"></object><embed src=\"x.swf\">u", want: "u"),
    Case(input: "<form action=\"/x\"><input name=a><button>go</button></form>", want: "go"),
    Case(input: "<span style=\"color:red\">a</span><font color=red>b</font><u>c</u>", want: "abc"),
    Case(input: "a<!-- one -->b<!-- <b>two</b> -->c", want: "abc"),
    Case(input: "<b>a</b><!-- never closed <b>b</b>", want: "<b>a</b>"),
    Case(input: "<!--><script>alert(1)</script>-->", want: "--&gt;"),
    Case(input: "<!---><b>x</b>", want: "<b>x</b>"),
    Case(input: "<!-- a --!><b>x</b>", want: "<b>x</b>"),
    Case(input: "<!--[if gte IE 4]><SCRIPT>alert(1)</SCRIPT><![endif]-->ok", want: "ok"),
    Case(input: "<!DOCTYPE html><?xml version=\"1.0\"?><![CDATA[<b>]]>x", want: "]]&gt;x"),
    Case(input: "</ b>a</>b</3>c", want: "abc"),
  ]
end

# The filter evasion tricks of the OWASP cheat sheet and their kin.
def xss_cases() -> List[Case]
  return [
    Case(input: "<IMG SRC=\"javascript:alert('XSS');\">", want: ""),
    Case(input: "<img src=x onerror=alert(1)>t", want: "t"),
    Case(input: "<IMG SRC=x onerror=\"alert(1)\"/>t", want: "t"),
    Case(input: "<img/src=x/onerror=alert(1)>t", want: "t"),
    Case(input: "<img src=\"x\" onerror=\"alert(1)\" <b>t", want: "t"),
    Case(input: "<img src=x onerror=alert(1)//", want: ""),
    Case(input: "<IMG \"\"\"><SCRIPT>alert(\"XSS\")</SCRIPT>\">", want: "\"&gt;"),
    Case(input: "<SCRIPT/XSS SRC=\"http://example.com/xss.js\"></SCRIPT>t", want: "t"),
    Case(input: "<BODY onload!#$%&()*~+-_.,:;?@[/|\\]^`=alert(\"XSS\")>t", want: "t"),
    Case(input: "<scr<script>ipt>alert(1)</scr</script>ipt>", want: "ipt&gt;alert(1)ipt&gt;"),
    Case(input: "<<script>alert(1)//<</script>", want: "&lt;"),
    Case(input: "<<b>script>alert(1)<</b>/script>", want: "&lt;<b>script&gt;alert(1)&lt;</b>/script&gt;"),
    Case(input: "&lt;script&gt;alert(1)&lt;/script&gt;", want: "&lt;script&gt;alert(1)&lt;/script&gt;"),
    Case(input: "<scr#{NUL}ipt>alert(1)</scr#{NUL}ipt>z", want: "z"),
    Case(input: "<p#{NUL} onclick=\"alert(1)\">a</p#{NUL}>", want: "<p>a</p>"),
    Case(input: "<img src=x onerror#{NUL}=alert(1)>a#{NUL}b", want: "ab"),
    Case(input: "<p onclick=\"alert(1)\" style=\"x:expression(alert(1))\">a</p>", want: "<p>a</p>"),
    Case(input: "<p\nonmouseover\n=\n\"alert(1)\"\n>a</p\n>", want: "<p>a</p>"),
    Case(input: "<b title=\"</b><script>alert(1)</script>\">x</b>", want: "<b>x</b>"),
    Case(input: "<img alt=\"</script><script>alert(1)</script>\">t", want: "t"),
    Case(
      input: "<a href=\"http://x\" title=\"</a><script>alert(1)</script>\">t</a>",
      want: "<a href=\"http://x\" #{LINK_REL}>t</a>",
    ),
    Case(input: "<a href=\"</script>\">x</a>", want: "<a href=\"&lt;/script&gt;\" #{LINK_REL}>x</a>"),
    Case(
      input: "<a href='http://x\" onclick=\"alert(1)'>x</a>",
      want: "<a href=\"http://x&quot; onclick=&quot;alert(1)\" #{LINK_REL}>x</a>",
    ),
    Case(input: "<a href=\"http://x>click</a><b>x</b>", want: ""),
    Case(input: "<a href=\"x\"onclick=alert(1)>t</a>", want: "<a href=\"x\" #{LINK_REL}>t</a>"),
    Case(input: "<a href=http://x onclick=alert(1)>t</a>", want: "<a href=\"http://x\" #{LINK_REL}>t</a>"),
    Case(
      input: "<a href=\"http://good\" href=\"javascript:alert(1)\">t</a>",
      want: "<a href=\"http://good\" #{LINK_REL}>t</a>",
    ),
    Case(input: "<a href=\"javascript:alert(1)\" href=\"http://good\">t</a>", want: "t"),
    Case(input: "<a\nhref=\"javascript:alert(1)\"\n>t</a>", want: "t"),
    Case(input: "<a/href=\"javascript:alert(1)\">t</a>", want: "t"),
    Case(input: "<a/href=\"http://x\">t</a>", want: "<a href=\"http://x\" #{LINK_REL}>t</a>"),
    Case(input: "<a href>t</a><a href=\"\">u</a><a name=\"x\">v</a>", want: "tuv"),
  ]
end

# The scheme of a link, written in every way that a browser reads as that scheme.
def scheme_cases() -> List[Case]
  return [
    Case(input: "<a href=\"javascript:alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"JaVaScRiPt:alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"  javascript:alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"jav&#x09;ascript:alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"jav&#x0A;ascript:alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"jav&#13;ascript:alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"jav\tasc\nript:alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"&#x6A;&#x61;vascript&#x3A;alert(1)\">x</a>", want: "x"),
    Case(
      input: "<a href=\"&#0000106&#0000097vascript&#0000058alert(1)\">x</a>",
      want: "<a href=\"&amp;#0000106&amp;#0000097vascript&amp;#0000058alert(1)\" #{LINK_REL}>x</a>",
    ),
    Case(
      input: "<a href=\"javascript&colon;alert(1)\">x</a>",
      want: "<a href=\"javascript&amp;colon;alert(1)\" #{LINK_REL}>x</a>",
    ),
    Case(input: "<a href=\"java&Tab;script:alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"java#{NUL}script:alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"java#{String.from_code(1)}script:alert(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"vbscript:msgbox(1)\">x</a>", want: "x"),
    Case(input: "<a href=\"data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==\">x</a>", want: "x"),
    Case(input: "<a href=\"file:///etc/passwd\">x</a><a href=\"ftp://x\">y</a><a href=\"tel:1\">z</a>", want: "xyz"),
    Case(input: "<a href=\"HTTPS://example.com\">x</a>", want: "<a href=\"HTTPS://example.com\" #{LINK_REL}>x</a>"),
    Case(input: "<a href=\"//example.com/x\">x</a>", want: "<a href=\"//example.com/x\" #{LINK_REL}>x</a>"),
    Case(
      input: "<a href=\"/a:b\">x</a><a href=\"?u=javascript:1\">y</a>",
      want: "<a href=\"/a:b\" #{LINK_REL}>x</a><a href=\"?u=javascript:1\" #{LINK_REL}>y</a>",
    ),
  ]
end

# The first case that the sanitizer does not turn into what it should, named by its input.
def run_cases(cases: List[Case]) -> Result[Void]
  for c in cases
    got = HtmlSanitizer.sanitize(c.input)
    if got != c.want
      return error("sanitize(#{c.input.inspect}) is #{got.inspect}, want #{c.want.inspect}")
    end
  end

  return ok()
end

# Every `<` of the output opens an allowed tag; only a link has attributes, and they are the two that it writes.
def only_allowed_markup?(html: String) -> Bool
  for piece in html.split("<").drop(1)
    tag = piece.split(">")[0]
    if not piece.include?(">")
      return false
    end

    name = tag.split(" ")[0].split("/").join("")
    if not OUTPUT_TAGS.include?(name)
      return false
    end

    if tag.include?(" ") and not link_tag?(tag)
      return false
    end
  end

  return true
end

def link_tag?(tag: String) -> Bool
  if not (tag.start_with?("a href=\"") and tag.end_with?("\" #{LINK_REL}"))
    return false
  end

  address = tag.slice(8, tag.length - 8 - LINK_REL.length - 2)
  return not address.include?("\"") and not address.include?("<") and not address.include?(">")
end

# Whatever comes in, the output is safe markup, and sanitizing it again changes nothing.
def run_invariants(cases: List[Case]) -> Result[Void]
  for c in cases
    got = HtmlSanitizer.sanitize(c.input)
    if not only_allowed_markup?(got)
      return error("sanitize(#{c.input.inspect}) is #{got.inspect}, which has markup that is not allowed")
    end

    again = HtmlSanitizer.sanitize(got)
    if again != got
      return error("sanitize(#{c.input.inspect}) is #{got.inspect} and the second pass makes #{again.inspect}")
    end
  end

  return ok()
end

# The steps of one sanitize of `piece` repeated `times` times.
def steps_of(piece: String, times: Int) -> Int
  input = List.repeat(piece, times).join("")
  before = Profile.steps()
  HtmlSanitizer.sanitize(input)
  return Profile.steps() - before
end

# Four times the input must cost about four times the steps; a scan that starts again at each tag or each end tag
# makes it sixteen.
def linear?(piece: String) -> Result[Void]
  small = steps_of(piece, 200)
  large = steps_of(piece, 800)
  return Test.assert(large < small * 5, "#{piece.inspect}: #{small} steps for 200 and #{large} for 800")
end

def main() -> Void
  Test.run([
    Test.test("the bodies of Action Text keep their markup and lose their attributes") do
      run_cases(action_text_cases())
    end,
    Test.test("text is escaped and tags are closed in order") do run_cases(well_formed_cases()) end,
    Test.test("what is not allowed is dropped, scripts and comments with their content") do
      run_cases(dropped_cases())
    end,
    Test.test("the evasion tricks of the XSS cheat sheet come out as plain text or nothing") do
      run_cases(xss_cases())
    end,
    Test.test("a link keeps http, https, mailto and a relative address, in whatever way the scheme is written") do
      run_cases(scheme_cases())
    end,
    Test.test("every output is made of allowed tags only and is a fixed point") do
      cases = action_text_cases().concat(well_formed_cases()).concat(dropped_cases()).concat(xss_cases())
      try run_invariants(cases.concat(scheme_cases()))
      run_invariants([
        Case(input: "<a href=\"x\" <a href=\"y\">", want: ""),
        Case(input: "<<<<>>>><a<b>c>", want: ""),
        Case(input: "<a href=\"&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;\">x</a>", want: ""),
        Case(input: "<a href='\"><script>alert(1)</script>'>x</a>", want: ""),
        Case(input: "<table><b><tr><td></b></td></tr></table></a></b>", want: ""),
      ])
    end,
    Test.test("nesting is capped") do
      out = HtmlSanitizer.sanitize(List.repeat("<b>", 200).join("") + "x")
      try Test.eq(out.split("<b>").size, 65)
      Test.eq(out.split("</b>").size, 65)
    end,
    Test.test("the cost grows with the input") do
      try linear?("<p>text <b>bold</b> &amp; <a href=\"http://x/?a=1&b=2\">link</a></p>")
      try linear?("<b>")
      try linear?("</i>")
      linear?("&#x")
    end,
    Test.test("the cost grows with the input, also for what is made to slow a parser down") do
      try linear?("<")
      try linear?("<!--")
      try linear?("<a href=\"")
      linear?("<p a=b ")
    end,
    Test.test("the cost grows with the input, also for a script that never ends") do
      try linear?("<a href=\"javascript:x\" ")
      try linear?("<script>")
      try linear?("</script x=\"<")
      linear?("<script></scrip")
    end,
  ])
end

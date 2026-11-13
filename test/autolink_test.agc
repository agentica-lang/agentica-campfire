import Autolink from "../src/campfire/autolink"

private

REL = "rel=\"noopener noreferrer\""

struct Case
  input: String
  want: String
end

def blank(url: String, shown: String) -> String = "<a target=\"_blank\" href=\"#{url}\" #{REL}>#{shown}</a>"

def cases() -> List[Case]
  [
    Case(input: "no links here", want: "no links here"),
    Case(input: "time 10:30 or a ratio 3:2", want: "time 10:30 or a ratio 3:2"),
    Case(
      input: "see https://example.com/a?b=1&amp;c=2 now",
      want: "see #{blank("https://example.com/a?b=1&amp;c=2", "https://example.com/a?b=1&amp;c=2")} now",
    ),
    Case(input: "<p>www.example.com</p>", want: "<p>#{blank("http://www.example.com", "www.example.com")}</p>"),
    Case(input: "WWW.Example.com/X", want: blank("http://WWW.Example.com/X", "WWW.Example.com/X")),
    Case(input: "Go to http://example.com.", want: "Go to #{blank("http://example.com", "http://example.com")}."),
    Case(
      input: "(http://example.com/a_(b))",
      want: "(#{blank("http://example.com/a_(b)", "http://example.com/a_(b)")})",
    ),
    Case(input: "(http://example.com/a)", want: "(#{blank("http://example.com/a", "http://example.com/a")})"),
    Case(input: "\"http://example.com/a\"", want: "\"#{blank("http://example.com/a", "http://example.com/a")}\""),
    Case(
      input: "&lt;http://example.com/a&gt;",
      want: "&lt;#{blank("http://example.com/a", "http://example.com/a")}&gt;",
    ),
    Case(input: "http://example.com/é, ok", want: "#{blank("http://example.com/é", "http://example.com/é")}, ok"),
    Case(input: "http://example.com/a”", want: "#{blank("http://example.com/a", "http://example.com/a")}”"),
    Case(
      input: "ftp://x file:///etc/passwd ssh://host mailto://x",
      want: "ftp://x file:///etc/passwd ssh://host mailto://x",
    ),
    Case(input: "http://. https://, www. www.!", want: "http://. https://, www. www.!"),
    Case(input: "http://a.com/&quot;x", want: blank("http://a.com/&quot;x", "http://a.com/&quot;x")),
    Case(input: "http://a.com/&#34; y", want: "#{blank("http://a.com/&#34;", "http://a.com/&#34;")} y"),
    Case(input: "é日本 http://example.com/ü", want: "é日本 #{blank("http://example.com/ü", "http://example.com/ü")}"),
    Case(
      input: "mail ana@example.com, or <b>bea.b+c@mail.example.org</b>",
      want: (
        "mail #{blank("mailto:ana@example.com", "ana@example.com")}, or <b>#{blank("mailto:bea.b+c@mail.example.org", "bea.b+c@mail.example.org")}</b>"
      ),
    ),
    Case(input: "x@localhost and @name and a@b", want: "x@localhost and @name and a@b"),
    Case(input: "&x@y.com", want: "&x@y.com"),
    Case(input: "http://user@example.com/", want: blank("http://user@example.com/", "http://user@example.com/")),
    Case(input: "javascript:alert(1) and data:text/html,x", want: "javascript:alert(1) and data:text/html,x"),
    Case(
      input: "<pre>see http://example.com</pre>",
      want: "<pre>see #{blank("http://example.com", "http://example.com")}</pre>",
    ),
  ]
end

# A link that is already one is left alone, its text and its address, and the text after it is linked.
def existing_link_case() -> Case
  link = "<a href=\"http://example.com/x\" #{REL}>http://example.com/x and a@b.com</a>"
  Case(input: "#{link} then www.b.org", want: "#{link} then #{blank("http://www.b.org", "www.b.org")}")
end

def main() -> Void
  Test.run([
    Test.test("URLs and email addresses in the text become links, as rails_autolink makes them") do
      for c in cases()
        try Test.eq(Autolink.link(c.input), c.want)
      end

      Test.eq(Autolink.link(existing_link_case().input), existing_link_case().want)
    end,
    Test.test("a long run of closing brackets is read in one pass") do
      url = "http://example.com/" + List.repeat(")", 20_000).join("")
      Test.eq(
        Autolink.link(url),
        "#{blank("http://example.com/", "http://example.com/")}#{List.repeat(")", 20_000).join("")}",
      )
    end,
  ])
end

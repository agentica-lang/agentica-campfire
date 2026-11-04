import Views from "../src/campfire_web/views"

def main() -> Void
  Test.run([
    Test.test("the layout escapes the title and keeps the content that the caller made") do
      page = Views.layout("<b>x</b> & y", "<p>ok</p>")
      try Test.assert(page.include?("<title>&lt;b&gt;x&lt;/b&gt; &amp; y</title>"), page)
      Test.assert(page.include?("<p>ok</p>"), page)
    end,
  ])
end

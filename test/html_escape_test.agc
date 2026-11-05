import Bond from "pkg/bond/bond"
import HtmlEscape from "pkg/html_escape/html_escape"

# The five characters, text with none of them, UTF-8 of two to four bytes beside them, a NUL (which C never sees), and
# texts longer than the 64 KiB that the C buffer keeps, before and after short ones, so it grows and gives the memory
# back.
def samples() -> List[String]
  long = "<a href=\"x?a=1&b='2'\">héllo ✓ 😀</a> plain text " * 2_000
  return [
    "",
    "plain",
    "&<>\"'",
    "&&<<>>\"\"''",
    "&amp; &lt; already escaped",
    "<script>alert('x')</script>",
    "héllo ✓ 日本語 😀 <b>&</b>",
    "a#{String.from_code(0)}<b>",
    long,
    "short after long & <>",
    "x" * 100_000,
    long + long,
    "end",
  ]
end

def main() -> Void
  Test.run([
    Test.test("the native escape gives what Bond.escape gives") do
      failed = samples().select do |text| HtmlEscape.escape(text) != Bond.escape(text) end
      Test.eq(failed.map do |text| text.slice(0, 40) end, [])
    end,
  ])
end

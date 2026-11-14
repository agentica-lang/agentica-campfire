import HtmlSanitizer from "../src/campfire/html_sanitizer"
import Mentions from "../src/campfire/mentions"

private

PEOPLE = [
  Mentions.Person(id: 2, name: "Bea"),
  Mentions.Person(id: 3, name: "Bea Lopez"),
  Mentions.Person(id: 4, name: "O'Neil & Co"),
]

def m(id: Int, name: String) -> String = Mentions.markup(id, name)

def typed(text: String) -> String = Mentions.link(HtmlSanitizer.from_text(text), PEOPLE)

def main() -> Void
  Test.run([
    Test.test("a typed @NAME of one of the people is a mention, the longest name first, with no word around it") do
      try Test.eq(typed("@Bea Lopez and @Bea."), "#{m(3, "Bea Lopez")} and #{m(2, "Bea")}.")
      try Test.eq(typed("ana@Bea.com @Beatrix @Bea_x @@Bea"), "ana@Bea.com @Beatrix @Bea_x @#{m(2, "Bea")}")
      Test.eq(typed("hi @O'Neil & Co!"), "hi #{m(4, "O'Neil & Co")}!")
    end,
    Test.test("the mentions round-trip: the ids, the cleaning and the settling leave them as they are") do
      body = typed("@Bea Lopez, @Bea and @Bea")
      try Test.eq(Mentions.ids(body), [3, 2])
      try Test.eq(HtmlSanitizer.sanitize(body), body)
      try Test.eq(Mentions.settle(body, PEOPLE), body)
      try Test.eq(HtmlSanitizer.text_of_clean(body), "@Bea Lopez, @Bea and @Bea")
      Test.eq(typed(HtmlSanitizer.text_of_clean(body)), body)
    end,
    Test.test("settling names a mention after the person, and leaves the text of one of anybody else") do
      body = HtmlSanitizer.sanitize(
        "#{HtmlSanitizer.mention_open(2)}<b>@Old</b></action-text-attachment> and #{HtmlSanitizer.mention_open(9)}@Gone</action-text-attachment>!",
      )

      Test.eq(Mentions.settle(body, PEOPLE), "#{m(2, "Bea")} and @Gone!")
    end,
  ])
end

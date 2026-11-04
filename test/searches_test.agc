import Searches from "../src/campfire/searches"

def main() -> Void
  Test.run([
    Test.test("what is typed is words: anything that is not a letter, digit or underscore separates them") do
      try Test.eq(Searches.words("Coffee, & tea!"), "Coffee tea")
      try Test.eq(Searches.words("  salt   AND  "), "salt AND")
      try Test.eq(Searches.words("snake_case \"quoted\" (x) a-b"), "snake_case quoted x a b")
      try Test.eq(Searches.words("café naïve 日本語"), "café naïve 日本語")
      Test.eq(Searches.words("!!! ... ---"), "")
    end,
    Test.test("each word is in double quotes, so FTS5 reads it as text and not as an operator") do
      try Test.eq(Searches.match("salt AND NEAR"), "\"salt\" \"AND\" \"NEAR\"")
      try Test.eq(Searches.match(""), "")
      Test.eq(Searches.match("a\"b"), "\"a\"\"b\"")
    end,
  ])
end

import Transfers from "../src/campfire/transfers"

private

def main() -> Void
  Test.run([
    Test.test("a link gives its person once") do
      links = Transfers.new()
      token = Transfers.issue(links, 7, 1000).unwrap!
      try Test.assert(Transfers.redeem(links, token, 2000) == some(7), "the first use")
      Test.assert(Transfers.redeem(links, token, 3000).none?, "the second use")
    end,
    Test.test("a link expires after its lifetime, and the sweep forgets it") do
      links = Transfers.new()
      token = Transfers.issue(links, 7, 1000).unwrap!
      try Test.assert(Transfers.redeem(links, token, 1000 + Transfers.LIFETIME_MS).none?, "at the end of its life")
      _ = Transfers.issue(links, 8, 1000 + Transfers.LIFETIME_MS)
      Test.assert(Transfers.redeem(links, token, 1000).none?, "after the sweep, even at an earlier time")
    end,
    Test.test("a token that was never made, and another person's, give nobody else") do
      links = Transfers.new()
      token = Transfers.issue(links, 7, 1000).unwrap!
      other = Transfers.issue(links, 8, 1000).unwrap!
      try Test.assert(token != other, "two tokens differ")
      try Test.assert(Transfers.redeem(links, "0" * 64, 1000).none?, "an unknown token")
      Test.assert(Transfers.redeem(links, other, 1000) == some(8), "the other person")
    end,
  ])
end

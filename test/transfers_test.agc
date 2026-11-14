import Transfers from "../src/campfire/transfers"

private

struct Attempt
  links: Transfers.Links
  token: String
end

def main() -> Void
  Test.run([
    Test.test("a link gives its person and its session once") do
      links = Transfers.new()
      token = Transfers.issue(links, 7, 70, 1000)
      try Test.assert(
        Transfers.redeem(links, token, 2000) == some(Transfers.Grant(user_id: 7, session_id: 70)),
        "the first use",
      )

      Test.assert(Transfers.redeem(links, token, 3000).none?, "the second use")
    end,
    Test.test("a link expires after its lifetime") do
      links = Transfers.new()
      token = Transfers.issue(links, 7, 70, 1000)
      Test.assert(Transfers.redeem(links, token, 1000 + Transfers.LIFETIME_MS).none?, "at the end of its life")
    end,
    Test.test("a new link of a person ends the last, and the tables keep one link and one claim a person") do
      links = Transfers.new()
      first = Transfers.issue(links, 7, 70, 1000)
      try Test.assert(Transfers.redeem(links, first, 1000).some?, "the first link")
      second = Transfers.issue(links, 7, 70, 1000)
      try Test.assert(Transfers.redeem(links, first, 1000).none?, "the first link after the second")
      try Test.assert(Transfers.redeem(links, second, 1000).some?, "the second link")
      for _ in 0...100
        _ = Transfers.issue(links, 7, 70, 1000)
      end

      try Test.assert(ATS.size(links.links) == 1, "one link")
      Test.assert(ATS.size(links.claims) <= 2, "the serial and at most one claim")
    end,
    Test.test("a token that was never made, and another person's, give nobody else") do
      links = Transfers.new()
      token = Transfers.issue(links, 7, 70, 1000)
      other = Transfers.issue(links, 8, 80, 1000)
      try Test.assert(token != other, "two tokens differ")
      try Test.assert(Transfers.redeem(links, "7-" + "0" * 64, 1000).none?, "an unknown secret")
      try Test.assert(
        Transfers.redeem(links, "8-" + token.slice(2, token.length - 2), 1000).none?,
        "a secret of 7 as 8",
      )

      try Test.assert(Transfers.redeem(links, "nobody", 1000).none?, "no dash")
      Test.assert(Transfers.redeem(links, other, 1000).some?, "the other person")
    end,
    Test.test("of two tasks that use one link at once, one gets the person") do
      links = Transfers.new()
      token = Transfers.issue(links, 7, 70, 1000)
      tasks = (1..2).map do |_| Task.spawn(&attempt, Attempt(links: links, token: token)) end
      grants = tasks.map { |task| Task.await(task) }
      wins = grants.select { |grant| grant.some? }
      Test.assert(wins.size == 1, "#{wins.size} uses")
    end,
  ])
end

def attempt(given: Attempt) -> Optional[Transfers.Grant] = Transfers.redeem(given.links, given.token, 2000)

import Passwords from "../src/campfire/passwords"

# What `verify_nobody?` must cost to hide that an email is not registered: well over the time of a rejected digest.
MIN_WORK_MS = 20

def main() -> Void
  Test.run([
    Test.test("a digest verifies the password that made it and no other, and does not hold it") do
      digest = Passwords.hash("correct horse battery").unwrap!
      try Test.assert(Passwords.verify?("correct horse battery", digest), digest)
      try Test.assert(not Passwords.verify?("correct horse batterz", digest), digest)
      try Test.assert(digest.start_with?("scrypt$"), digest)
      Test.assert(not digest.include?("correct horse"), digest)
    end,
    Test.test("each digest has its own salt") do
      Test.assert(Passwords.hash("same password").unwrap! != Passwords.hash("same password").unwrap!, "same digest")
    end,
    Test.test("a text that is not one of our digests verifies nothing") do
      try Test.assert(not Passwords.verify?("x", ""), "empty")
      try Test.assert(not Passwords.verify?("x", "plain"), "plain")
      try Test.assert(not Passwords.verify?("x", "bcrypt$65536$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AA=="), "scheme")
      try Test.assert(not Passwords.verify?("x", "scrypt$65536$8$2$not base64$AA=="), "salt")
      Test.assert(
        not Passwords.verify?("x", "scrypt$3$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AA=="),
        "cost that is not a power of 2",
      )
    end,
    Test.test("checking against nobody takes the work of a real check") do
      started = Time.now_ms()
      try Test.assert(not Passwords.verify_nobody?(), "nobody has a password")
      Test.assert(Time.now_ms() - started >= MIN_WORK_MS, "the check was too quick to hide a missing user")
    end,
    Test.test("a new password needs 8 characters and at most 256 bytes") do
      try Test.eq(Passwords.problem("correct horse"), "")
      try Test.assert(Passwords.problem("short") != "", "short")
      try Test.assert(Passwords.problem("12345678") == "", "exactly the minimum")
      Test.assert(Passwords.problem((0...257).to_a.map do |_| "x" end.join("")) != "", "long")
    end,
  ])
end

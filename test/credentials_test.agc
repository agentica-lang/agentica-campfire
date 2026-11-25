import Bcrypt from "../src/campfire/bcrypt"
import Credentials from "../src/campfire/credentials"
import Password from "pkg/password/password"

private

# What a refused digest must cost to hide that it is one: the work of a hash is far over it.
MIN_WORK_MS = 20

def main() -> Void
  Test.run([
    Test.test("a digest of the package verifies its password and no other") do
      digest = Password.hash("correct horse battery").unwrap!
      try Test.eq(Credentials.verify("correct horse battery", digest), ok(true))
      Test.eq(Credentials.verify("correct horse batterz", digest), ok(false))
    end,
    Test.test("a stored digest that is not one is a failed check that costs the work of a hash, not an error") do
      for digest in ["", "plain", "$1$salt$hashhashhashhashhashhash", "scrypt$3$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AA=="]
        started = Time.now_ms()
        try Test.eq(Credentials.verify("x", digest), ok(false))
        try Test.assert(Time.now_ms() - started >= MIN_WORK_MS, "the check of #{digest.inspect} was too quick")
      end

      return ok()
    end,
    Test.test("the limit of a password is the one that the bcrypt check takes") do
      Test.eq(Password.MAX_BYTES, Bcrypt.MAX_PASSWORD_BYTES)
    end,
  ])
end

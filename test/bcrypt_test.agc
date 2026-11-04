import Bcrypt from "../src/campfire/bcrypt"
import Passwords from "../src/campfire/passwords"

# Digests that other implementations made, and the passwords that made them. The first five are the vectors of the
# crypt_blowfish test suite (Openwall, `wrapper.c`; OpenBSD and libxcrypt test the same ones), which bcrypt-ruby gives
# back too. `$2b$` is from pyca/bcrypt (Python), `$2y$` from PHP's `password_hash`, and the `$2a$12$` ones from Ruby's
# bcrypt gem, which is what `has_secure_password` of Rails calls (cost 12 is its default).
WRAPPER_VECTORS = [
  ["U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"],
  ["U*U*", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK"],
  ["U*U*U", "$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a"],
  ["", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy"],
  [
    "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored",
    "$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui",
  ],
  ["Kk4DQuMMfZL9o", "$2b$04$cVWp4XaNU8a4v1uMRum2SO026BWLIoQMD/TXg5uZV.0P.uO8m3YEm"],
  ["secret-password", "$2b$04$UG3YtrQhF1zPxFoJD1xZMekAw7n4Krqhj2PoZGIRLnUtMhBtsNeIq"],
  ["secret-password", "$2y$04$CXxbbFo6fuFlmT39vHoMJOx5CHCN0f7Htpbomo0UnoVwHw.N5iaU."],
  ["ünïcode pässwörd", "$2a$04$cmZs.e/GjWtiYsE9MlsdmOmBWaJX5qvkdz.AVABH1r0efwI84lDjS"],
  ["correct horse battery", "$2a$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6KQoUDvUdMi"],
  ["correct horse battery", "$2y$12$1jFHU53lJapRtuGG/Se1qO0ZjSPSvBewzTvJ0T4DbNo1jZJv.mTm."],
]

# The library that the tests use: the one of `CAMPFIRE_BCRYPT_LIBRARY` when it is set (a macOS or Windows runner with a
# libxcrypt build), else the default of the system.
def library() -> String
  return System.env("CAMPFIRE_BCRYPT_LIBRARY").unwrap_or("")
end

# Whether this system can check bcrypt digests, so the tests that need the library are skipped (they pass without
# running) where it is missing. Linux with no library set must have it: there a failure is a failure.
def ready() -> Result[Bool]
  probe = Bcrypt.verify("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW", library())
  if probe.ok?
    return ok(true)
  end

  if System.os() == "linux" and library().empty?
    return error("libcrypt.so.1 cannot check bcrypt: #{probe.message}")
  end

  return ok(false)
end

def main() -> Void
  Test.run([
    Test.test("every known digest verifies the password that made it, through Passwords.verify too") do
      if not try ready()
        return ok()
      end

      for pair in WRAPPER_VECTORS
        try Test.assert(Bcrypt.verify(pair[0], pair[1], library()).unwrap!, pair[1])
        try Test.assert(Passwords.verify(pair[0], pair[1], library()).unwrap!, pair[1])
      end

      return ok()
    end,
    Test.test("a wrong password, a changed letter and a longer password do not verify") do
      if not try ready()
        return ok()
      end

      digest = "$2a$12$.e8gNYy3Yc5qIeU31tvPEuAmRhK8AsHV7iZLhpvYgB6KQoUDvUdMi"
      try Test.assert(not Bcrypt.verify("correct horse batterz", digest, library()).unwrap!, "wrong")
      try Test.assert(not Bcrypt.verify("Correct horse battery", digest, library()).unwrap!, "case")
      try Test.assert(not Bcrypt.verify("correct horse battery ", digest, library()).unwrap!, "longer")
      try Test.assert(not Bcrypt.verify("", digest, library()).unwrap!, "empty")
      Test.assert(
        not Bcrypt.verify("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK", library()).unwrap!,
        "other",
      )
    end,
    Test.test("bcrypt reads the first 72 bytes of a password only, and a NUL in it is refused") do
      if not try ready()
        return ok()
      end

      long = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored"
      digest = "$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui"
      try Test.assert(Bcrypt.verify(long.slice(0, 72) + " other", digest, library()).unwrap!, "same first 72 bytes")
      try Test.assert(not Bcrypt.verify(long.slice(0, 71), digest, library()).unwrap!, "71 bytes")
      nul = String.from_bytes("U*U".bytes + Bytes.from_list([0, 88]).unwrap!).unwrap!
      Test.assert(
        not Bcrypt.verify(nul, "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW", library()).unwrap!,
        "NUL",
      )
    end,
    Test.test("a text that is not a bcrypt digest of a usable shape is false") do
      good = "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"
      bad = [
        "",
        "$2a$",
        "$2x$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW",
        "$2a$03$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW",
        "$2a$32$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW",
        "$2a$+5$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW",
        "$2a$05CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW$",
        good.slice(0, 59),
        good + "x",
        "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOe!",
        "$1$salt$hashhashhashhashhashhash",
      ]

      for text in bad
        try Test.assert(not Bcrypt.digest?(text), text)
        try Test.assert(not Bcrypt.verify("U*U", text).unwrap!, text)
      end

      try Test.assert(Bcrypt.digest?(good), "good")
      try Test.assert(
        Bcrypt.digest?("$2y$31$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"),
        "cost 31 has a shape",
      )

      Test.assert(Passwords.verify("x", "$1$salt$hashhashhashhashhashhash").unwrap! == false, "not ours")
    end,
    Test.test("a cost over the limit is an error that says so, and runs nothing") do
      started = Time.now_ms()
      checked = Bcrypt.verify("x", "$2b$20$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW")
      try Test.assert(not checked.ok?, "a cost of 20 ran")
      try Test.assert(checked.message.include?("limit of #{Bcrypt.MAX_COST}"), checked.message)
      Test.assert(Time.now_ms() - started < 1000, "it took the time of the hash")
    end,
    Test.test(
      "the library is the one that is set, else libcrypt.so.1 on Linux, else an error that says what to set",
    ) do
      try Test.eq(Bcrypt.library_for("linux", ""), ok("libcrypt.so.1"))
      try Test.eq(Bcrypt.library_for("linux", "/opt/lib/libcrypt.so"), ok("/opt/lib/libcrypt.so"))
      try Test.eq(
        Bcrypt.library_for("macos", "/opt/homebrew/opt/libxcrypt/lib/libcrypt.1.dylib").unwrap!.size > 0,
        true,
      )

      for os in ["macos", "windows"]
        problem = Bcrypt.library_for(os, "")
        try Test.assert(not problem.ok?, os)
        try Test.assert(problem.message.include?("CAMPFIRE_BCRYPT_LIBRARY"), problem.message)
      end

      return ok()
    end,
    Test.test(
      "a library that is missing, or has no crypt_r, is an error that names the variable, never a wrong password",
    ) do
      digest = "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"
      missing = Bcrypt.verify("U*U", digest, "/nonexistent/libcrypt.so.1")
      try Test.assert(not missing.ok?, "a library that is not there was used")
      try Test.assert(missing.message.include?("cannot open /nonexistent/libcrypt.so.1"), missing.message)
      try Test.assert(missing.message.include?("CAMPFIRE_BCRYPT_LIBRARY"), missing.message)
      # The system's own maths library opens but has no `crypt_r`.
      if System.os() != "linux"
        return ok()
      end

      bare = Bcrypt.verify("U*U", digest, "libm.so.6")
      try Test.assert(not bare.ok?, "a library without crypt_r was used")
      try Test.assert(bare.message.include?("has no crypt_r"), bare.message)
      Test.assert(bare.message.include?("CAMPFIRE_BCRYPT_LIBRARY"), bare.message)
    end,
  ])
end

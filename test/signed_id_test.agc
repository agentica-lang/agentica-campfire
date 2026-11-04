import SignedId from "../src/campfire/signed_id"

# Tokens that Rails made: a real app (`Rails::Application` with this `secret_key_base`, a `User` model, `signed_id`) of
# Rails 7.1.5, 7.2.2 and 8.0.2, run in a ruby:3.3 container, as `user.signed_id(purpose: :avatar)`. Rails 7.2 and 8.0
# write the same tokens; 7.1 writes the plain, padded base64, and `load_defaults 7.0` the older envelope.
SECRET = (
  "5d1f1c3e0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f"
)
KEY_HEX = (
  "fb1d27846b838705fda8de769f62c8c0684df441a9f127086c263de5e443873c53e5f033293eb5c1667cfd8cb98bf10b5257be2c65c4116d043404470ce5c144"
)

# 2026-11-04 in Unix milliseconds, and 2100-01-01T00:00:00Z, the `exp` of one token.
NOW_MS = 1_793_750_400_000
EXPIRY_2100_MS = 4_102_444_800_000

RAILS_8_ID_1 = (
  "eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0--5841e05747f2d37ddbe2647ead7fe82ebed32d2062d87a8d28975c2501972b85"
)
RAILS_8_ID_42 = (
  "eyJfcmFpbHMiOnsiZGF0YSI6NDIsInB1ciI6InVzZXIvYXZhdGFyIn19--ef87430eae10b22fca259ec0b28b3af3123583239cb94a098ccffaafadf8c97e"
)
RAILS_8_ID_1000000 = (
  "eyJfcmFpbHMiOnsiZGF0YSI6MTAwMDAwMCwicHVyIjoidXNlci9hdmF0YXIifX0--fb0ee2602d70ac8088e89c211ab14eba0f30a5a24e2863b0ba87bbabd9ada45c"
)
RAILS_7_1_ID_42 = (
  "eyJfcmFpbHMiOnsiZGF0YSI6NDIsInB1ciI6InVzZXIvYXZhdGFyIn19--ef87430eae10b22fca259ec0b28b3af3123583239cb94a098ccffaafadf8c97e"
)
RAILS_7_1_ID_1 = (
  "eyJfcmFpbHMiOnsiZGF0YSI6MSwicHVyIjoidXNlci9hdmF0YXIifX0=--6dca05c53b2c8662ec2451929719a1a6eb628b4ead8e3df875fd30829c5dc2bd"
)
RAILS_7_0_ID_42 = (
  "eyJfcmFpbHMiOnsibWVzc2FnZSI6Ik5EST0iLCJleHAiOm51bGwsInB1ciI6InVzZXIvYXZhdGFyIn19--0496a5515c40bda3bfd37a6cab083f21110da05fdbc41f022f133869aa909664"
)
PLAIN_ID_42 = (
  "eyJfcmFpbHMiOnsiZGF0YSI6NDIsInB1ciI6InVzZXIifX0--f9175aeb4fb9058aaec13a9aa8b3a59b883282b429cc34f41bb194f4aed23975"
)
EXPIRES_2100 = (
  "eyJfcmFpbHMiOnsiZGF0YSI6NDIsImV4cCI6IjIxMDAtMDEtMDFUMDA6MDA6MDAuMDAwWiIsInB1ciI6InVzZXIvYXZhdGFyIn19--b52e904daa280604d4985405b26ca730d313415ea95bab37f878833dfe736eea"
)
EXPIRED_2000 = (
  "eyJfcmFpbHMiOnsiZGF0YSI6NDIsImV4cCI6IjIwMDAtMDEtMDFUMDA6MDA6MDAuMDAwWiIsInB1ciI6InVzZXIvYXZhdGFyIn19--e7e87f3b36162d1f072f33fe376e59be88432fb30ef9d71a651ea537a8f52620"
)
# Rails 7.1.5, purpose "avataré?": the plain base64 has a "/" in it, which the URL-safe alphabet writes "_".
RAILS_7_1_SLASH = (
  "eyJfcmFpbHMiOnsiZGF0YSI6NDIsInB1ciI6InVzZXIvYXZhdGFyw6k/In19--114825a495b1ba10b7ba54651b6947afd2540b730f11c30e048ac43da29dc6a0"
)
OTHER_SECRET = (
  "eyJfcmFpbHMiOnsiZGF0YSI6NDIsInB1ciI6InVzZXIvYXZhdGFyIn19--b6171f5a67a8d5310d4801c106c630c5d77959c1ee6c8002cfc33fafcb656df5"
)

def key() -> Bytes
  return SignedId.key(SECRET).unwrap!
end

def main() -> Void
  Test.run([
    Test.test("the key is the one that Rails derives: PBKDF2-SHA256, 1000 rounds, the salt of signed_id, 64 bytes") do
      Test.eq(Digest.hexencode(key()), KEY_HEX)
    end,
    Test.test("the tokens of Rails 7.1, 7.2 and 8.0 give the id of the user") do
      try Test.eq(SignedId.verify(key(), RAILS_8_ID_1, SignedId.AVATAR_PURPOSE, NOW_MS), some(1))
      try Test.eq(SignedId.verify(key(), RAILS_8_ID_42, SignedId.AVATAR_PURPOSE, NOW_MS), some(42))
      try Test.eq(SignedId.verify(key(), RAILS_8_ID_1000000, SignedId.AVATAR_PURPOSE, NOW_MS), some(1_000_000))
      try Test.eq(SignedId.verify(key(), RAILS_7_1_ID_1, SignedId.AVATAR_PURPOSE, NOW_MS), some(1))
      try Test.eq(SignedId.verify(key(), RAILS_7_1_ID_42, SignedId.AVATAR_PURPOSE, NOW_MS), some(42))
      try Test.eq(SignedId.verify(key(), RAILS_7_0_ID_42, SignedId.AVATAR_PURPOSE, NOW_MS), some(42))
      try Test.eq(SignedId.verify(key(), EXPIRES_2100, SignedId.AVATAR_PURPOSE, NOW_MS), some(42))
      # The plain base64 of Rails 7.1 has "+" and "/" where the URL-safe one has "-" and "_".
      try Test.eq(SignedId.verify(key(), RAILS_7_1_SLASH, "user/avataré?", NOW_MS), some(42))
      Test.eq(SignedId.verify(key(), EXPIRES_2100, SignedId.AVATAR_PURPOSE, EXPIRY_2100_MS - 1), some(42))
    end,
    Test.test("a token that Rails would not accept gives none") do
      purpose = SignedId.AVATAR_PURPOSE
      # The same id with no purpose ("user"), a purpose that is another one, a token of another secret, and an expiry
      # that has passed.
      try Test.eq(SignedId.verify(key(), PLAIN_ID_42, purpose, NOW_MS), none)
      try Test.eq(SignedId.verify(key(), RAILS_8_ID_42, "user/other", NOW_MS), none)
      try Test.eq(SignedId.verify(key(), RAILS_8_ID_42, "", NOW_MS), none)
      try Test.eq(SignedId.verify(key(), OTHER_SECRET, purpose, NOW_MS), none)
      try Test.eq(SignedId.verify(key(), EXPIRED_2000, purpose, NOW_MS), none)
      # Expired at the very millisecond of `exp`, as Rails has it (`Time.now.utc >= exp`).
      Test.eq(SignedId.verify(key(), EXPIRES_2100, purpose, EXPIRY_2100_MS), none)
    end,
    Test.test("a token that was changed or cut gives none") do
      purpose = SignedId.AVATAR_PURPOSE
      parts = RAILS_8_ID_42.split("--")
      other_id = "eyJfcmFpbHMiOnsiZGF0YSI6NDMsInB1ciI6InVzZXIvYXZhdGFyIn19"
      broken = [
        other_id + "--" + parts[1],
        parts[0] + "--" + parts[1].upcase,
        parts[0] + "--" + parts[1].slice(0, 63),
        parts[0] + "-" + parts[1],
        parts[0],
        "--" + parts[1],
        "",
        "--",
        RAILS_8_ID_42 + "0",
      ]

      for token in broken
        try Test.eq(SignedId.verify(key(), token, purpose, NOW_MS), none)
      end

      return ok()
    end,
    Test.test("a signed envelope that is not an id gives none") do
      purpose = SignedId.AVATAR_PURPOSE
      # Signed by the right key, so only the content can refuse them: a string for the id, no `_rails`, not JSON.
      for json in [
        "{\"_rails\":{\"data\":\"7\",\"pur\":\"user/avatar\"}}", "{\"data\":7,\"pur\":\"user/avatar\"}", "nope", "7",
      ]
        encoded = Base64.urlsafe_encode64(json.bytes, false)
        token = "#{encoded}--#{HMAC.sha256_hexdigest(key(), encoded.bytes)}"
        try Test.eq(SignedId.verify(key(), token, purpose, NOW_MS), none)
      end

      return ok()
    end,
    Test.test("a token made here is the token of Rails, and verifies") do
      made = SignedId.generate(key(), 42, SignedId.AVATAR_PURPOSE).unwrap!
      try Test.eq(made, RAILS_8_ID_42)
      try Test.eq(SignedId.generate(key(), 1_000_000, SignedId.AVATAR_PURPOSE).unwrap!, RAILS_8_ID_1000000)
      try Test.eq(SignedId.verify(key(), made, SignedId.AVATAR_PURPOSE, NOW_MS), some(42))
      try Test.assert(not SignedId.generate(key(), 42, "").ok?, "empty purpose")
      Test.assert(not SignedId.generate(key(), 42, "user/\"x").ok?, "a purpose that needs escaping")
    end,
    Test.test("an empty secret has no key") do Test.assert(not SignedId.key("").ok?, "empty") end,
  ])
end

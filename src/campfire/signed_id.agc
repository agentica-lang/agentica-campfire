## Rails `signed_id` tokens, as the links of upstream Campfire carry them (`/users/TOKEN/avatar` is
## `user.signed_id(purpose: :avatar)`), made and checked from `SECRET_KEY_BASE`, the secret of a Rails app. A token is
## the id, its purpose and an optional expiry, signed. It is not encrypted: anybody can read the id in it; the
## signature is what stops a person from changing it.
##
## What Rails does (Active Record 7.1 to 8.0, `signed_id.rb`, `message_verifier.rb`, `key_generator.rb`):
##
## 1. The key is `Rails.application.key_generator.generate_key("active_record/signed_id")`: PBKDF2-HMAC with 1000
##    iterations, the hash that `config.load_defaults` 7.0 and later set (SHA-256; apps from before 7.0 use SHA-1, which
##    this module does not read), the salt `"active_record/signed_id"` and a key of 64 bytes (`key`).
## 2. `ActiveSupport::MessageVerifier.new(key, digest: "SHA256", serializer: JSON, url_safe: true)` makes
##    `base64(json) + "--" + hex(HMAC-SHA256(key, base64(json)))`. The base64 is the URL-safe one without padding from
##    Rails 7.2 (7.1 writes the plain, padded one, and `verify` reads both).
## 3. The json is `{"_rails":{"data":ID,"exp":"2100-01-01T00:00:00.000Z","pur":"user/avatar"}}` (`exp` only when the
##    token expires). The purpose of a model is `"user/" + purpose` (`combine_signed_id_purposes`: the model name
##    underscored, a slash, the purpose). Before `load_defaults` 7.1 the envelope holds `"message"` (the base64 of the
##    json of the id) and `"exp"` and `"pur"`, which `verify` reads too.

import UTC from "std/utc"

## The purpose of the avatar link of a user in Campfire.
export AVATAR_PURPOSE = "user/avatar"

SALT = "active_record/signed_id"
ITERATIONS = 1000
KEY_BYTES = 64
SEPARATOR = "--"
# The hex of HMAC-SHA256.
DIGEST_LENGTH = 64
# `exp` as Rails writes it (`iso8601(3)` of a UTC time): 2100-01-01T00:00:00.000Z.
EXPIRY_LENGTH = 24
PLAIN_PURPOSE = Set.new("abcdefghijklmnopqrstuvwxyz0123456789_/-".split(""))

# The part of the envelope that is read: `data` in the form of Rails 7.1 and later, `message` in the older one.
struct Envelope
  data: Optional[Int] = none
  message: Optional[String] = none
  exp: Optional[String] = none
  pur: Optional[String] = none
end

## The signing key for `secret_key_base`. Make it once, at start-up: 1000 rounds of PBKDF2 are cheap, but there is no
## reason to repeat them.
export def key(secret_key_base: String) -> Result[Bytes]
  if secret_key_base.empty?
    return error("signed id: SECRET_KEY_BASE is empty")
  end

  return OpenSSL.KDF.pbkdf2_hmac_sha256(secret_key_base.bytes, SALT.bytes, ITERATIONS, KEY_BYTES)
end

## The token for `id` and `purpose` (`AVATAR_PURPOSE`), without an expiry, in the form of Rails 7.2 and later. A purpose
## is lowercase letters, digits and `_`, `/`, `-`, which is all that a model name and a purpose are, so it needs no
## JSON escaping.
export def generate(key: Bytes, id: Int, purpose: String) -> Result[String]
  if purpose.empty? or not purpose.split("").all? do |ch| PLAIN_PURPOSE.include?(ch) end
    return error("signed id: the purpose #{purpose.inspect} is not a plain one")
  end

  json = "{\"_rails\":{\"data\":#{id},\"pur\":\"#{purpose}\"}}"
  encoded = Base64.urlsafe_encode64(json.bytes, false)
  return ok("#{encoded}#{SEPARATOR}#{OpenSSL.HMAC.sha256_hexdigest(key, encoded.bytes)}")
end

## The id in `token` when it was signed with `key`, for `purpose`, and has not expired at `now_ms` (Unix milliseconds,
## `Time.now_ms()`); `none` for anything else. The reason is not told, as in Rails (`find_signed` is nil). The
## signature is checked before the text is decoded, in constant time.
export def verify(key: Bytes, token: String, purpose: String, now_ms: Int) -> Optional[Int]
  cut = token.length - DIGEST_LENGTH - SEPARATOR.length
  if cut <= 0 or token.slice(cut, SEPARATOR.length) != SEPARATOR
    return none
  end

  encoded = token.slice(0, cut)
  digest = token.slice(cut + SEPARATOR.length, DIGEST_LENGTH)
  if not OpenSSL.HMAC.secure_compare(OpenSSL.HMAC.sha256_hexdigest(key, encoded.bytes).bytes, digest.bytes)
    return none
  end

  envelope = envelope_of(encoded)
  if envelope.none? or envelope.unwrap!.pur != some(purpose) or expired?(envelope.unwrap!.exp, now_ms)
    return none
  end

  return id_of(envelope.unwrap!)
end

# The decoded envelope, from the URL-safe base64 of Rails 7.2 or the plain one of 7.1.
def envelope_of(encoded: String) -> Optional[Envelope]
  bytes = Base64.urlsafe_decode64(encoded)
  if not bytes.ok?
    bytes = Base64.strict_decode64(encoded)
  end

  text = String.from_bytes(bytes.unwrap_or("".bytes))
  parsed = JSON.parse(text.unwrap_or(""))
  if not text.ok? or not parsed.ok?
    return none
  end

  inner = JSON.get(parsed.unwrap!, "_rails")
  if not inner.ok?
    return none
  end

  envelope = JSON.decode(inner.unwrap!, Envelope)
  if not envelope.ok?
    return none
  end

  return some(envelope.unwrap!)
end

def id_of(envelope: Envelope) -> Optional[Int]
  if envelope.data.some?
    return envelope.data
  end

  if envelope.message.none?
    return none
  end

  # The older envelope holds the json of the id, in plain base64 (`"MQ=="` is 1).
  bytes = Base64.strict_decode64(envelope.message.unwrap!)
  text = String.from_bytes(bytes.unwrap_or("".bytes))
  number = text.unwrap_or("").to_i
  if not text.ok? or not number.ok?
    return none
  end

  return some(number.unwrap!)
end

# A token with an expiry that is not in the form of Rails is refused as if it had expired. Both texts have the same
# shape, so the order of the strings is the order of the times.
def expired?(exp: Optional[String], now_ms: Int) -> Bool
  if exp.none?
    return false
  end

  text = exp.unwrap!
  if text.length != EXPIRY_LENGTH or not text.end_with?("Z")
    return true
  end

  return text.compare(UTC.iso8601(now_ms, 3)) <= 0
end

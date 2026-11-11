## Password hashing with scrypt. A digest is one text, `scrypt$N$r$p$salt$key` (salt and key in base64), so it carries
## the cost that made it and `verify` still works after the cost is raised for new passwords. `verify` also checks the
## bcrypt digests of a Rails Campfire (`bcrypt.agc`); nothing makes one.

import Bcrypt from "bcrypt"

# OWASP's scrypt setting for a cost of 2^16 (64 MiB of memory) with two lanes. The call runs to its end on its
# scheduler (see `OpenSSL.KDF` in the library), so this is the time one sign-in takes of it. Since Agentica 0.24.0 it
# runs on the compute pool; `Slots` in `AuthWeb` still bounds how many run at once, for their memory.
COST = 65_536
BLOCK_SIZE = 8
PARALLELISM = 2
KEY_BYTES = 32
SALT_BYTES = 16
SCHEME = "scrypt"
BCRYPT_PREFIX = "$2"
NOBODY_SALT = "nobody has this password"
NOBODY_PASSWORD = "nobody"
DIGEST_PARTS = 6

MIN_LENGTH = 8

## The most bytes of a password. `sign_in` refuses a longer one without hashing it.
export MAX_BYTES = 256

## What is wrong with `password` as a new password, or "" when it is fine.
export def problem(password: String) -> String
  return "The password needs at least #{MIN_LENGTH} characters" if password.length < MIN_LENGTH

  return "The password can have at most #{MAX_BYTES} bytes" if password.bytes.size > MAX_BYTES

  ""
end

## The digest of `password` with a new random salt. It never holds the password.
export def hash(password: String) -> Result[String]
  salt = OpenSSL.Random.random_bytes(SALT_BYTES)
  key = try OpenSSL.KDF.scrypt(password.bytes, salt, COST, BLOCK_SIZE, PARALLELISM, KEY_BYTES)
  ok("#{SCHEME}$#{COST}$#{BLOCK_SIZE}$#{PARALLELISM}$#{Base64.strict_encode64(salt)}$#{Base64.strict_encode64(key)}")
end

## True when `password` is the one that made `digest`, an scrypt digest of ours or a bcrypt one (`$2a$`, `$2b$`,
## `$2y$`). A digest that is not one of those, or an scrypt cost that the system refuses, is false. An `error` is a
## bcrypt digest on a system that cannot check it (see `Bcrypt.verify`), which says nothing about the password. The
## keys are compared in constant time. `bcrypt_library` is `CAMPFIRE_BCRYPT_LIBRARY` ("" for the default).
export def verify(password: String, digest: String, bcrypt_library: String = "") -> Result[Bool]
  return Bcrypt.verify(password, digest, bcrypt_library) if digest.start_with?(BCRYPT_PREFIX)

  ok(verify_scrypt?(password, digest))
end

## Does the work of `verify` for a password that nobody has, with the cost of `hash`, and gives false. Sign-in calls
## it for an email that no user has, so that the time does not tell whether the email is registered. Its result is
## ignored at the call sites: it exists for its cost.
export def verify_nobody?() -> Bool
  key = OpenSSL.KDF.scrypt(NOBODY_PASSWORD.bytes, NOBODY_SALT.bytes, COST, BLOCK_SIZE, PARALLELISM, KEY_BYTES)
  # A key is never empty (it has KEY_BYTES), so this is false; it reads the key so the work is not dropped.
  key.ok? and key.unwrap!.empty?
end

def verify_scrypt?(password: String, digest: String) -> Bool
  parts = digest.split("$")
  return false if parts.size != DIGEST_PARTS or parts[0] != SCHEME

  cost = parts[1].to_i
  block_size = parts[2].to_i
  parallelism = parts[3].to_i
  salt = Base64.strict_decode64(parts[4])
  expected = Base64.strict_decode64(parts[5])
  return false if not (cost.ok? and block_size.ok? and parallelism.ok? and salt.ok? and expected.ok?)

  key = OpenSSL.KDF.scrypt(
    password.bytes,
    salt.unwrap!,
    cost.unwrap!,
    block_size.unwrap!,
    parallelism.unwrap!,
    expected.unwrap!.size,
  )

  key.ok? and OpenSSL.HMAC.secure_compare(key.unwrap!, expected.unwrap!)
end

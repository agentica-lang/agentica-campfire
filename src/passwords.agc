## Password hashing with scrypt. A digest is one text, `scrypt$N$r$p$salt$key` (salt and key in base64), so it carries
## the cost that made it and `verify?` still works after the cost is raised for new passwords.

# OWASP's scrypt setting for a cost of 2^16 (64 MiB of memory) with two lanes. The call runs to its end on its
# scheduler (see `KDF` in the library), so this is the time one sign-in takes of it. Until the builtin can be moved off
# the scheduler (agentica-lang/agentica#1049), `Slots` in `AuthWeb` bounds how many run at once.
COST = 65_536
BLOCK_SIZE = 8
PARALLELISM = 2
KEY_BYTES = 32
SALT_BYTES = 16
SCHEME = "scrypt"
NOBODY_SALT = "nobody has this password"
NOBODY_PASSWORD = "nobody"
DIGEST_PARTS = 6

MIN_LENGTH = 8

## The most bytes of a password. `sign_in` refuses a longer one without hashing it.
export MAX_BYTES = 256

## What is wrong with `password` as a new password, or "" when it is fine.
export def problem(password: String) -> String
  if password.length < MIN_LENGTH
    return "The password needs at least #{MIN_LENGTH} characters"
  end

  if password.bytes.size > MAX_BYTES
    return "The password can have at most #{MAX_BYTES} bytes"
  end

  return ""
end

## The digest of `password` with a new random salt. It never holds the password.
export def hash(password: String) -> Result[String]
  salt = SecureRandom.random_bytes(SALT_BYTES)
  key = try KDF.scrypt(password.bytes, salt, COST, BLOCK_SIZE, PARALLELISM, KEY_BYTES)
  return ok(
    "#{SCHEME}$#{COST}$#{BLOCK_SIZE}$#{PARALLELISM}$#{Base64.strict_encode64(salt)}$#{Base64.strict_encode64(key)}",
  )
end

## True when `password` is the one that made `digest`. A digest that is not one of ours, or a cost that the system
## refuses, is false. The keys are compared in constant time.
export def verify?(password: String, digest: String) -> Bool
  parts = digest.split("$")
  if parts.size != DIGEST_PARTS or parts[0] != SCHEME
    return false
  end

  cost = parts[1].to_i
  block_size = parts[2].to_i
  parallelism = parts[3].to_i
  salt = Base64.strict_decode64(parts[4])
  expected = Base64.strict_decode64(parts[5])
  if not (cost.ok? and block_size.ok? and parallelism.ok? and salt.ok? and expected.ok?)
    return false
  end

  key = KDF.scrypt(
    password.bytes,
    salt.unwrap!,
    cost.unwrap!,
    block_size.unwrap!,
    parallelism.unwrap!,
    expected.unwrap!.size,
  )

  return key.ok? and HMAC.secure_compare(key.unwrap!, expected.unwrap!)
end

## Does the work of `verify?` for a password that nobody has, with the cost of `hash`, and gives false. Sign-in calls
## it for an email that no user has, so that the time does not tell whether the email is registered.
export def verify_nobody?() -> Bool
  key = KDF.scrypt(NOBODY_PASSWORD.bytes, NOBODY_SALT.bytes, COST, BLOCK_SIZE, PARALLELISM, KEY_BYTES)
  # A key is never empty (it has KEY_BYTES), so this is false; it reads the key so the work is not dropped.
  return key.ok? and key.unwrap!.empty?
end

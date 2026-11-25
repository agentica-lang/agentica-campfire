## The check of a stored password digest: the bcrypt digests of a Rails Campfire go to `bcrypt.agc`, every other text to
## the `password` package. A stored text that is not a digest at all (empty, damaged, written by something else, or a `$2`
## that is not bcrypt-shaped) is a failed sign-in, not a crash: it is logged without the digest, and it costs the work of
## a hash like any wrong password.

import Password from "pkg/password/password"
import Bcrypt from "bcrypt"

## True when `password` is the one that made `digest`, the digest stored for the person `user_id` (only for the log). A
## password of more than `Password.MAX_BYTES` bytes is false after the work of a hash. An `error` is a bcrypt digest on a
## system that cannot check it (see `Bcrypt.verify`), which says nothing about the password. `bcrypt_library` is
## `CAMPFIRE_BCRYPT_LIBRARY` ("" for the default).
def verify(password: String, digest: String, user_id: Int, bcrypt_library: String = "") -> Result[Bool]
  if password.bytes.size > Password.MAX_BYTES
    Password.verify_nobody()
    return ok(false)
  end

  return Bcrypt.verify(password, digest, bcrypt_library) if Bcrypt.digest?(digest)

  verdict = Password.verify(password, digest)
  return verdict if verdict.ok?

  IO.warn("campfire: the password digest of user #{user_id} was refused: #{verdict.message}")
  Password.verify_nobody()
  ok(false)
end

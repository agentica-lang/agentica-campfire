## The check of a stored password digest: the bcrypt digests of a Rails Campfire go to `bcrypt.agc`, every other digest to
## the `password` package. A stored digest that is not a digest at all (empty, damaged, written by something else) is a
## failed sign-in, not a crash: it is logged without the digest, and it costs the work of a hash like any wrong password.

import Password from "pkg/password/password"
import Bcrypt from "bcrypt"

BCRYPT_PREFIX = "$2"

## True when `password` is the one that made `digest`. An `error` is a bcrypt digest on a system that cannot check it (see
## `Bcrypt.verify`), which says nothing about the password. `bcrypt_library` is `CAMPFIRE_BCRYPT_LIBRARY` ("" for the
## default).
def verify(password: String, digest: String, bcrypt_library: String = "") -> Result[Bool]
  return Bcrypt.verify(password, digest, bcrypt_library) if digest.start_with?(BCRYPT_PREFIX)

  verdict = Password.verify(password, digest)
  return verdict if verdict.ok?

  IO.warn("campfire: a stored password digest was refused: #{verdict.message}")
  Password.verify_nobody()
  ok(false)
end

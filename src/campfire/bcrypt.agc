## Checking bcrypt digests, the form that Rails' `has_secure_password` writes (`$2a$12$` and the salt and the hash, 60
## characters), so people who come from a Rails Campfire can sign in with the digests they have. Nothing here makes a
## bcrypt digest: new passwords are scrypt (`Passwords.hash`).
##
## There is no bcrypt in the language, so the check goes through the FFI to `crypt_r` of a libcrypt that has it. On
## Linux that is libxcrypt (`libcrypt.so.1`: Debian 10, Ubuntu 18.10, Fedora 29, RHEL 8 and later). macOS has no bcrypt
## in its libc and Windows has no `crypt`, so there `CAMPFIRE_BCRYPT_LIBRARY` names a libxcrypt build; it replaces the
## default on Linux too. The library is opened by name when a digest is checked (`dlopen`, or `LoadLibrary` on
## Windows) and `crypt_r` is called through the address that the system gives, so a library that is missing, or has no
## bcrypt, is an `error` of that check and never stops the app (a function that an `extern` names and the library lacks
## would).

# The bcrypt digest: `$2a$` (or `$2b$`, `$2y$`), a two-digit cost, a 22 character salt and a 31 character hash, all in
# bcrypt's own base 64 alphabet.
DIGEST_LENGTH = 60
PREFIX_LENGTH = 7
COST_START = 4
COST_LENGTH = 2
BODY_START = 7
VERSIONS = Set.new(["$2a$", "$2b$", "$2y$"])
ALPHABET = Set.new("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".split(""))
DIGITS = Set.new("0123456789".split(""))

# A cost of 12 (Rails' default) takes about a quarter of a second, and each step up doubles it. A digest sits in the
# database, so a cost above this is not made by the person who signs in; it is refused rather than run for minutes on
# a thread of the compute pool.
MIN_COST = 4
LIMIT_COST = 31
export MAX_COST = 15

# The most bytes of a password that reaches the library: the same limit as `Passwords.MAX_BYTES`, which the sign-in
# applies before. bcrypt reads 72 of them, and libxcrypt refuses a passphrase of 512 bytes or more (which would look
# like a library without bcrypt), so a longer password is handled as one that cannot be checked.
export MAX_PASSWORD_BYTES = 256

# What is checked in place of a password that cannot be, so that the time is the one of a wrong password.
STAND_IN = "nobody has this password"

LINUX_LIBRARY = "libcrypt.so.1"
VARIABLE = "CAMPFIRE_BCRYPT_LIBRARY"
RESET_HELP = "or have the person reset their password to get an scrypt one"
# `RTLD_NOW` of Linux and macOS.
RTLD_NOW = 2

# What C's `struct crypt_data` takes. libxcrypt's is 32,768 bytes and glibc's own, from before libxcrypt, 131,232;
# `crypt_r` takes no size, so the buffer has room for either.
CRYPT_DATA_BYTES = 262_144

## True when `text` is a bcrypt digest of a shape that `verify` can check: a version `2a`, `2b` or `2y`, a cost from 04
## to 31 and the 53 characters of salt and hash.
export def digest?(text: String) -> Bool
  if text.length != DIGEST_LENGTH or not VERSIONS.include?(text.slice(0, COST_START))
    return false
  end

  digits = text.slice(COST_START, COST_LENGTH)
  if not digits.split("").all? do |ch| DIGITS.include?(ch) end or text.slice(COST_START + COST_LENGTH, 1) != "$"
    return false
  end

  cost = digits.to_i!
  if cost < MIN_COST or cost > LIMIT_COST
    return false
  end

  return text.slice(BODY_START, DIGEST_LENGTH - BODY_START).split("").all? do |ch| ALPHABET.include?(ch) end
end

## The library to open on the system `os` (`System.os()`) when `configured` (`CAMPFIRE_BCRYPT_LIBRARY`, "" when not
## set) is: that library, else `libcrypt.so.1` on Linux. Elsewhere there is none: an `error` that says what to set.
export def library_for(os: String, configured: String) -> Result[String]
  if not configured.empty?
    return ok(configured)
  end

  if os == "linux"
    return ok(LINUX_LIBRARY)
  end

  return error(
    "bcrypt digests have no library to check them on #{os}: set #{VARIABLE} to a libxcrypt build, #{RESET_HELP}",
  )
end

## True when `password` is the one that made `digest`. A text that is not a bcrypt digest is false at once. A password
## that cannot be checked as it is, with a NUL (bcrypt stops reading at one, and C strings cannot hold it) or over
## `MAX_PASSWORD_BYTES` (bcrypt reads 72), is false too, but only after a real check of a fixed password against the
## same digest, so the time does not tell it from a wrong password. An `error` is a system that cannot do the check
## (the library cannot be opened or has no bcrypt, a cost over `MAX_COST`): it says so, names `CAMPFIRE_BCRYPT_LIBRARY`
## and is not a verdict on the password. `library` is that variable ("" for the default of the system, see
## `library_for`). The work runs on the compute pool, so it does not hold a scheduler. Like bcrypt itself it reads the
## first 72 bytes of the password only. The hashes are compared in constant time.
export def verify(password: String, digest: String, library: String = "") -> Result[Bool]
  if not digest?(digest)
    return ok(false)
  end

  cost = digest.slice(COST_START, COST_LENGTH).to_i!
  if cost > MAX_COST
    return error(
      "bcrypt cost #{cost} is over the limit of #{MAX_COST}: this person cannot sign in until their password is " +
      "reset (or the cost of the digest is lowered)",
    )
  end

  has_nul = password.bytes.to_a.any? do |byte| byte == 0 end
  usable = not has_nul and password.bytes.size <= MAX_PASSWORD_BYTES
  attempt = password
  if not usable
    attempt = STAND_IN
  end

  name = try library_for(System.os(), library)
  crypt = try find_crypt(System.os(), name)
  made = try hashed(crypt, attempt, digest)
  return ok(usable and OpenSSL.HMAC.secure_compare(made.bytes, digest.bytes))
end

# The address of `crypt_r` in the library `name`.
def find_crypt(os: String, name: String) -> Result[C.Pointer]
  handle = open_library(os, name)
  if Native.null?(handle)
    return error(
      "cannot open #{name}, so bcrypt digests cannot be checked: set #{VARIABLE} to a libxcrypt, #{RESET_HELP}",
    )
  end

  found = find_symbol(os, handle, "crypt_r")
  if Native.null?(found)
    return error("#{name} has no crypt_r: set #{VARIABLE} to a libxcrypt, #{RESET_HELP}")
  end

  return ok(found)
end

def open_library(os: String, name: String) -> C.Pointer
  if os == "windows"
    return load_library(name)
  end

  if os == "linux"
    return dlopen(name, RTLD_NOW)
  end

  return dlopen_system(name, RTLD_NOW)
end

def find_symbol(os: String, handle: C.Pointer, symbol: String) -> C.Pointer
  if os == "windows"
    return get_proc_address(handle, symbol)
  end

  if os == "linux"
    return dlsym(handle, symbol)
  end

  return dlsym_system(handle, symbol)
end

# The digest that `password` makes with the version, cost and salt of `setting` (a digest has the same first 29
# characters). A libcrypt without bcrypt answers a failure token that is not 60 characters, or something else that is
# not a bcrypt digest: that is a system problem, so it is an error.
def hashed(crypt: C.Pointer, password: String, setting: String) -> Result[String]
  return Native.memory_pointer(CRYPT_DATA_BYTES) do |data| run_crypt(crypt, password, setting, data) end
end

def run_crypt(crypt: C.Pointer, password: String, setting: String, data: C.Pointer) -> Result[String]
  found = crypt_r_at(crypt, password, setting, data)
  if Native.null?(found)
    return error("the library refused the bcrypt digest: set #{VARIABLE} to a libxcrypt, #{RESET_HELP}")
  end

  made = Native.get_string(found, 0)
  if made.length != DIGEST_LENGTH or made.slice(0, PREFIX_LENGTH) != setting.slice(0, PREFIX_LENGTH)
    return error("the library has no bcrypt: set #{VARIABLE} to a libxcrypt, #{RESET_HELP}")
  end

  return ok(made)
end

# The loaders, one block for each system (a library is opened at the first call, so the blocks of the other systems
# cost nothing), and `crypt_r` through the address that they gave: a call through an address opens no library of its
# own, so `crypt_r_at` sits in the first block only because a block needs a name.
extern "libdl.so.2"
  def dlopen(path: C.String, flags: C.Int32) -> C.Pointer
  def dlsym(handle: C.Pointer, name: C.String) -> C.Pointer
  compute def crypt_r_at(fn: C.Function, phrase: C.String, setting: C.String, data: C.Pointer) -> C.Pointer
end

extern "libSystem.B.dylib"
  def dlopen_system(path: C.String, flags: C.Int32) -> C.Pointer = "dlopen"
  def dlsym_system(handle: C.Pointer, name: C.String) -> C.Pointer = "dlsym"
end

extern "kernel32.dll"
  def load_library(path: C.String) -> C.Pointer = "LoadLibraryA"
  def get_proc_address(handle: C.Pointer, name: C.String) -> C.Pointer = "GetProcAddress"
end

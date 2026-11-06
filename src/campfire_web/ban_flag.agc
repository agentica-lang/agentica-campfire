## Whether any ban exists, kept in memory so that the check of a write does not take a connection and run a query when
## there is none (the usual case; the benchmark posts messages all day). The flag is unknown until the first write asks,
## and is then read from the `bans` table once. A ban sets it before it writes, so a ban that commits is never missed;
## lifting a ban reads it again after the commit. Only the ban and the unban of this app change `bans` while it runs.

import Db from "pkg/db/db"
import Bans from "../campfire/bans"

KNOWN = "known"
ANY = "any"
CHANGES = "changes"

## A new flag, unknown, shared by every task that gets the handle.
export def new() -> ATS[String, Int]
  flag: ATS[String, Int] = ATS.new()
  return flag
end

## True once the flag has been read or set.
export def known?(flag: ATS[String, Int]) -> Bool
  return ATS.has_key?(flag, KNOWN)
end

## True when a ban may exist. An unknown flag says true: the caller reads the table.
export def any?(flag: ATS[String, Int]) -> Bool
  return not known?(flag) or ATS.get(flag, ANY).unwrap_or(0) > 0
end

## Sets the flag to `value`. Setting it true counts as a change that a `refresh` in progress must not undo.
export def mark(flag: ATS[String, Int], value: Bool) -> Void
  wanted = 0
  if value
    wanted = 1
    ATS.add(flag, CHANGES, 1)
  end

  ATS.put(flag, ANY, wanted)
  ATS.put(flag, KNOWN, 1)
end

## Reads the table and sets the flag from it. A "no ban" that was read before a ban set the flag is not written: the
## ban is newer than the read. What is left is a window of two memory operations between the check and the write,
## which the `mark` that a ban makes after its commit closes.
export def refresh(flag: ATS[String, Int], conn: Db.Connection) -> Result[Bool]
  before = ATS.get(flag, CHANGES).unwrap_or(0)
  found = try Bans.any?(conn)
  if found
    mark(flag, true)
    return ok(true)
  end

  if ATS.get(flag, CHANGES).unwrap_or(0) == before
    mark(flag, false)
    return ok(false)
  end

  return ok(true)
end

## The version of the database file, read on a connection of its own with plain calls into SQLite.
##
## Every cached page asks for the version before anything else, so this read is on the path of every request. It
## used to lease a connection from a pool of one, which cost about 250 µs of task hand-offs and serialized all the
## requests behind it (about 3.5k pages per second at most). Here a call is `step`, `column_int64` and `reset` on a
## statement that stays prepared: no task switch and no thread hop. `PRAGMA data_version` reads a counter in memory
## and does no I/O, and SQLite's busy timeout is 0 on this connection, so a call never waits long.
##
## The counter is per connection and counts only the commits of the other connections, so one connection must give
## every version (two would number the same state differently and could give one number to two states), and it
## must not be a connection of the pool that serves the requests (it would miss its own writes). Several schedulers
## call `version` at once, so two things keep them apart:
##
## - SQLite serializes each call on a connection (the open flag `FULLMUTEX` asks for that whatever the library was
##   built with).
## - A statement that has stepped keeps a read transaction open until it is reset, and a second statement stepped
##   meanwhile would share that old snapshot and could give the number from before a commit that was already
##   finished. The gate keeps one reader at a time between the step and the reset. It is a spin gate (a table entry,
##   taken and given back in a few microseconds, and a waiter yields to the scheduler), not a `Native.mutex`: a
##   mutex that parks the waiting scheduler cost 15 to 25 percent of the throughput in measurements.

import SqliteUrl from "pkg/db/sqlite/url"

SQLITE_ROW = 100
# SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX.
OPEN_FLAGS = 65_601
# The length argument that means "up to the NUL" for the sql.
NUL_TERMINATED = -1
SQL = "PRAGMA data_version"
SCHEME = "sqlite:"
GATE_KEY = 0
# A holder keeps the gate for microseconds. A waiter that finds it still taken after this many ms takes it over,
# because the holder is gone (a task cancelled between taking and giving it back), and the app must not stop with it.
STUCK_MS = 1_000
# How many yields a waiter makes between two looks at the clock.
SPINS_PER_CLOCK_LOOK = 256

extern "sqlite3"
  resource Handle, free: sqlite3_close_v2
  resource Stmt, free: sqlite3_finalize
  def sqlite3_open_v2(filename: C.String, out db: Handle, flags: C.Int32, vfs: C.Pointer) -> C.Int32
  def sqlite3_prepare_v2(db: Handle, sql: C.Pointer, bytes: C.Int32, out stmt: Stmt, out tail: C.Pointer) -> C.Int32
  def sqlite3_step(stmt: Stmt) -> C.Int32
  def sqlite3_reset(stmt: Stmt) -> C.Int32
  def sqlite3_column_int64(stmt: Stmt, col: C.Int32) -> C.Int64
  def sqlite3_errstr(code: C.Int32) -> C.String
end

## The connection and the gate that its readers take turns at. The task that opened it owns the connection.
export struct Reader
  db: Handle
  stmt: Stmt
  gate: ATS[Int, Bool]
end

## Opens a read-only connection to the database that `url` names (`sqlite:PATH`, as the pool takes it; the settings
## after a `?` do not matter here) and prepares the statement. The connection belongs to the task that calls this,
## which must live as long as the app does. An `error` says what failed.
export def open(url: String) -> Result[Reader]
  if not url.start_with?(SCHEME)
    return error("version reader: the database url must be sqlite:PATH, not #{url}")
  end

  target = try SqliteUrl.parse(url.slice(SCHEME.length, url.length - SCHEME.length))
  try Native.load("sqlite3")
  opened = sqlite3_open_v2(target.path, OPEN_FLAGS, Native.pointer(0))
  if opened.result != 0
    Native.close(opened.db)
    return error("version reader: cannot open #{target.path}: #{sqlite3_errstr(opened.result)}")
  end

  made = Native.from_string(SQL) do |sql| sqlite3_prepare_v2(opened.db, sql, NUL_TERMINATED) end
  if made.result != 0
    Native.close(opened.db)
    return error("version reader: cannot prepare #{SQL}: #{sqlite3_errstr(made.result)}")
  end

  gate: ATS[Int, Bool] = ATS.new()
  return ok(Reader(db: opened.db, stmt: made.stmt, gate: gate))
end

## Closes the connection, once the last reader is done: the app calls it after the server has stopped.
export def close(reader: Reader) -> Void
  enter(reader.gate)
  Native.close(reader.stmt)
  Native.close(reader.db)
  reader.gate.delete(GATE_KEY)
end

## A text that is the same for two calls only when no other connection committed in between. An `error` (the database
## is busy or the reader is closed) means that nothing is known, so the caller must not trust or keep anything it saw
## before.
export def version(reader: Reader) -> Result[String]
  enter(reader.gate)
  value = current(reader)
  reader.gate.delete(GATE_KEY)
  if value < 0
    return error("database error: PRAGMA data_version could not be read")
  end

  return ok(value.to_s)
end

# The counter, or -1. The one statement ends in `reset`, which closes its read transaction, so the next call sees the
# commits that were made since.
def current(reader: Reader) -> Int
  if Native.closed?(reader.stmt)
    return -1
  end

  value = -1
  if sqlite3_step(reader.stmt) == SQLITE_ROW
    value = sqlite3_column_int64(reader.stmt, 0)
  end

  _ = sqlite3_reset(reader.stmt)
  return value
end

# Takes the gate. A wait yields (`Task.sleep(0)`) so that the holder, which may be a task on this scheduler, runs.
def enter(gate: ATS[Int, Bool]) -> Void
  if gate.put_new(GATE_KEY, true)
    return
  end

  started = Time.now_ms()
  spins = 0
  while not gate.put_new(GATE_KEY, true)
    Task.sleep(0)
    spins += 1
    if spins % SPINS_PER_CLOCK_LOOK == 0 and Time.now_ms() - started > STUCK_MS
      gate.put(GATE_KEY, true)
      return
    end
  end
end

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
##   finished. The turn keeps one reader at a time between the step and the reset. It is a token in a channel of one
##   place: taking it is a `recv`, giving it back a `send`, and a reader that finds none waits as a task (the
##   scheduler runs others), so nothing parks a thread. It is not a `Native.mutex`: a mutex that parks the waiting
##   scheduler cost 15 to 25 percent of the throughput in measurements. A spin on a table entry was tried first and
##   burned the CPU of a machine with fewer cores than schedulers while the holder waited for its turn on one.

import SqliteUrl from "pkg/db/sqlite/url"

SQLITE_ROW = 100
# SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX.
OPEN_FLAGS = 65_601
# The length argument that means "up to the NUL" for the sql.
NUL_TERMINATED = -1
SQL = "PRAGMA data_version"
SCHEME = "sqlite:"
# A holder keeps the token for microseconds, unless its scheduler is starved of CPU. A waiter that has waited this
# long gives up (the page is made and not kept) and puts a token back, in case the holder is gone (a task cancelled
# between taking and giving it back), so that the app does not stop reading versions with it.
TURN_MS = 1_000

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

## The connection and the turn that its readers take. The task that opened it owns the connection.
export struct Reader
  db: Handle
  stmt: Stmt
  turn: Channel[Bool]
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

  turn: Channel[Bool] = Channel.new(1)
  _ = turn.send(true, 0)
  return ok(Reader(db: opened.db, stmt: made.stmt, turn: turn))
end

## Closes the connection, once the last reader is done: the app calls it after the server has stopped. A read after
## it is an `error`.
export def close(reader: Reader) -> Void
  if take(reader.turn)
    Native.close(reader.stmt)
    Native.close(reader.db)
    give_back(reader.turn)
  end
end

## A text that is the same for two calls only when no other connection committed in between. An `error` (the database
## is busy, the reader is closed or the turn did not come) means that nothing is known, so the caller must not trust
## or keep anything it saw before.
export def version(reader: Reader) -> Result[String]
  if not take(reader.turn)
    return error("database error: the version reader is busy")
  end

  value = current(reader)
  give_back(reader.turn)
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

# True when the token is ours. When it did not come in `TURN_MS` the holder is lost: a new token is put in so that the
# next readers are not stuck behind it too.
def take(turn: Channel[Bool]) -> Bool
  if turn.recv(TURN_MS).ok?
    return true
  end

  _ = turn.send(true, 0)
  return false
end

def give_back(turn: Channel[Bool]) -> Void
  _ = turn.send(true, 0)
end

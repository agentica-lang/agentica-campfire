## A limit on how many attempts one key (a client address) may make in a window of time, kept in an `ATS` table that
## the request tasks share. The window of a key starts at its first attempt, as the cache of upstream Campfire does,
## and ends `window_ms` later; the next attempt after it starts a new one. Two attempts that race at the turn of a
## window may count one too few: the limit is a brake on guessing, not an exact meter.

# Each key has two entries: when its window started and how many attempts it holds. A key never contains "|", since it
# is an IP address, so these names cannot clash with the sweep marker either.
STARTED = "|started"
COUNT = "|count"

# The time of the last sweep of old windows. Without a sweep a table keeps one pair of entries for every address that
# ever came.
SWEEP = "sweep"

MS_PER_SECOND = 1000

## A new table of windows, shared by every task that gets the handle.
export def new() -> ATS[String, Int]
  windows: ATS[String, Int] = ATS.new()
  return windows
end

## Counts an attempt of `key` at `now_ms` (a monotonic clock). It gives 0 when the attempt is one of the first `limit`
## of the window, and otherwise the whole seconds, at least 1, until the window ends and the key may try again.
export def hit(windows: ATS[String, Int], key: String, now_ms: Int, limit: Int, window_ms: Int) -> Int
  sweep(windows, now_ms, window_ms)
  began = window_start(windows, key, now_ms, window_ms)
  if ATS.add(windows, "#{key}#{COUNT}", 1) <= limit
    return 0
  end

  remaining_ms = began + window_ms - now_ms
  return (remaining_ms + MS_PER_SECOND - 1) / MS_PER_SECOND
end

# When the window of `key` started, after starting a new one if the last has ended or there was none.
def window_start(windows: ATS[String, Int], key: String, now_ms: Int, window_ms: Int) -> Int
  started_key = "#{key}#{STARTED}"
  if ATS.put_new(windows, started_key, now_ms)
    return now_ms
  end

  began = ATS.get(windows, started_key).unwrap_or(now_ms)
  if now_ms - began < window_ms
    return began
  end

  ATS.put(windows, started_key, now_ms)
  ATS.put(windows, "#{key}#{COUNT}", 0)
  return now_ms
end

# Once per window, drops the keys whose window ended. Two tasks that sweep together only do it twice.
def sweep(windows: ATS[String, Int], now_ms: Int, window_ms: Int) -> Void
  if ATS.put_new(windows, SWEEP, now_ms)
    return
  end

  if now_ms - ATS.get(windows, SWEEP).unwrap_or(now_ms) < window_ms
    return
  end

  ATS.put(windows, SWEEP, now_ms)
  for name in ATS.keys(windows)
    if name.end_with?(STARTED) and now_ms - ATS.get(windows, name).unwrap_or(now_ms) >= window_ms
      ATS.delete(windows, name)
      ATS.delete(windows, "#{name.slice(0, name.length - STARTED.length)}#{COUNT}")
    end
  end
end

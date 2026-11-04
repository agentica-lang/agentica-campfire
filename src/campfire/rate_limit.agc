## A limit on how many attempts one client may make in a window of time, kept in an `ATS` table that the request
## tasks share. A client is an IP address (an IPv6 one by its /64 prefix, since one person holds a whole /64 and could
## otherwise choose a new address for every attempt). The first window of a client starts at its first attempt and the
## next ones follow it back to back, each `window_ms` long; an attempt counts in the window it falls in, and never
## touches the count of another window, so counting needs no lock.
##
## The table is bounded: it holds at most `MAX_ENTRIES` entries (two or three for each client that is in a window). While
## it is full, the addresses that are not in it share one overflow client, with `OVERFLOW_FACTOR` times the limit of an
## address: a flood of addresses cannot grow the memory, hashing stays limited, and a person who is new still signs in
## unless the flood itself uses up the shared limit. Addresses already in the table keep their own counts. An unknown
## address ("") is one client like any other.

# The entries of a client `key`: when its first window started (`key|s`) and the attempts of each window
# (`key|c|WINDOW`). A key never contains "|", since it is an address. The sweep marker has no "|" either.
START = "|s"
COUNT = "|c|"
SWEEP = "sweep"

## The most entries the table holds before it counts the addresses it has not seen together. About 33,000 clients, and
## about 30 MB of memory when full.
export MAX_ENTRIES = 100_000

## How many times the limit of one address the overflow client gets, for all the addresses that are not in a full table.
export OVERFLOW_FACTOR = 10

# The key of the overflow client. An address is never "overflow", and it has no "|", so the sweep treats it as a client
# and drops it when idle.
OVERFLOW = "overflow"

MS_PER_SECOND = 1000
IPV6_GROUPS = 8
PREFIX_GROUPS = 4

## A new table of windows, shared by every task that gets the handle.
export def new() -> ATS[String, Int]
  windows: ATS[String, Int] = ATS.new()
  return windows
end

## Counts an attempt of the client at `address` at `now_ms` (a monotonic clock). It gives 0 when the attempt is one of
## the first `limit` of its window, and otherwise the whole seconds, at least 1, until the window ends and the next
## one starts (when the table is full and the address is not in it, the window and the limit are those of the overflow
## client). A sweep that runs at the same moment can make an attempt count once too many or too few, never more than
## the requests in flight.
export def hit(windows: ATS[String, Int], address: String, now_ms: Int, limit: Int, window_ms: Int) -> Int
  sweep(windows, now_ms, window_ms)
  key = key_of(address)
  if not ATS.has_key?(windows, "#{key}#{START}") and ATS.size(windows) >= MAX_ENTRIES
    # The overflow client takes at most three entries past the cap, since it is a client like any other.
    return count(windows, OVERFLOW, now_ms, limit * OVERFLOW_FACTOR, window_ms)
  end

  return count(windows, key, now_ms, limit, window_ms)
end

## The key of the client at `address`: an IPv4 address (or any text that is not IPv6) as it is, an IPv4-mapped IPv6
## address as its IPv4 address, and any other IPv6 address as its first 64 bits, `2001:db8:0:1::/64` written out in
## full. The system writes the address of a peer in lowercase and in one form, so no case or zero folding is done.
export def key_of(address: String) -> String
  if not address.include?(":")
    return address
  end

  if address.include?(".")
    return address.split(":").last
  end

  groups = expand(address)
  if groups.size != IPV6_GROUPS
    return address
  end

  return "#{groups.take(PREFIX_GROUPS).join(":")}::/64"
end

# Counts an attempt of the client `key` in its current window; the result is that of `hit`.
def count(windows: ATS[String, Int], key: String, now_ms: Int, limit: Int, window_ms: Int) -> Int
  start_key = "#{key}#{START}"
  ATS.put_new(windows, start_key, now_ms)
  began = ATS.get(windows, start_key).unwrap_or(now_ms)
  number = window_of(began, now_ms, window_ms)
  if ATS.add(windows, "#{key}#{COUNT}#{number}", 1) <= limit
    return 0
  end

  return seconds_up(began + (number + 1) * window_ms - now_ms)
end

# The eight groups of an IPv6 address, with the `::` filled in with zeros; fewer or more than eight when the text
# is not
# an address, which `key_of` keeps as it is.
def expand(address: String) -> List[String]
  halves = address.split("::")
  left: List[String] = []
  if not halves.empty?
    left = groups_of(halves[0])
  end

  if not address.include?("::")
    return left
  end

  # "2001:db8::" splits into one half, and "::1" into an empty one and "1".
  right: List[String] = []
  if halves.size == 2
    right = groups_of(halves[1])
  end

  missing = IPV6_GROUPS - left.size - right.size
  if missing < 0 or halves.size > 2
    return left.concat(right)
  end

  return left.concat(List.repeat("0", missing)).concat(right)
end

def groups_of(text: String) -> List[String]
  return text.split(":").select do |group| not group.empty? end
end

def window_of(began: Int, now_ms: Int, window_ms: Int) -> Int
  if now_ms <= began
    return 0
  end

  return (now_ms - began) / window_ms
end

def seconds_up(ms: Int) -> Int
  return (ms + MS_PER_SECOND - 1) / MS_PER_SECOND
end

# Once per window, drops what no attempt can count in again: the counts of windows that ended (and those of a client
# whose start is gone), and the start of a client that made no attempt in its current and previous windows. Entries of
# a window that is still open are never touched.
def sweep(windows: ATS[String, Int], now_ms: Int, window_ms: Int) -> Void
  if ATS.put_new(windows, SWEEP, now_ms)
    return
  end

  if now_ms - ATS.get(windows, SWEEP).unwrap_or(now_ms) < window_ms
    return
  end

  ATS.put(windows, SWEEP, now_ms)
  for name in ATS.keys(windows)
    parts = name.split("|")
    if parts.size == 3
      drop_count(windows, parts[0], parts[2].to_i.unwrap_or(0), now_ms, window_ms)
    elsif parts.size == 2 and parts[1] == "s"
      drop_start(windows, parts[0], now_ms, window_ms)
    end
  end
end

def drop_count(windows: ATS[String, Int], key: String, number: Int, now_ms: Int, window_ms: Int) -> Void
  began = ATS.get(windows, "#{key}#{START}")
  if not began.ok? or number < window_of(began.unwrap!, now_ms, window_ms)
    ATS.delete(windows, "#{key}#{COUNT}#{number}")
  end
end

def drop_start(windows: ATS[String, Int], key: String, now_ms: Int, window_ms: Int) -> Void
  began = ATS.get(windows, "#{key}#{START}")
  if not began.ok?
    return
  end

  number = window_of(began.unwrap!, now_ms, window_ms)
  recent = ATS.has_key?(windows, "#{key}#{COUNT}#{number}") or ATS.has_key?(windows, "#{key}#{COUNT}#{number - 1}")
  if not recent
    ATS.delete(windows, "#{key}#{START}")
  end
end

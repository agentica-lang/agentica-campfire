## A bounded queue of items that wait for a worker, with a limit of items running for one key. Tasks share it.

import Slots from "slots"

## The waiting items, the running ones of each key, and the lock that lets one `take` scan at a time. `probe_pause_ms`
## is for tests: when it is 0 or more, a scan waits that long between the probe of a key and its undo.
struct Queue[T]
  waiting: Channel[Entry[T]]
  counted: ATS[String, Int]
  running: ATS[String, Int]
  scanning: Channel[Bool]
  capacity: Int
  per_key: Int
  probe_pause_ms: Int = -1
end

## An item with its key.
struct Entry[T]
  key: String
  item: T
end

## A new queue that holds `capacity` items, and lets `per_key` of one key run.
def new[T](capacity: Int, per_key: Int, probe_pause_ms: Int = -1) -> Queue[T]
  waiting: Channel[Entry[T]] = Channel.new(capacity)
  scanning: Channel[Bool] = Channel.new(1)
  Queue(
    waiting: waiting,
    counted: Slots.new(),
    running: Slots.new(),
    scanning: scanning,
    capacity: capacity,
    per_key: per_key,
    probe_pause_ms: probe_pause_ms,
  )
end

## Adds an item at the back; false when the queue is full.
def offer[T](queue: Queue[T], key: String, item: T) -> Bool
  return false if not Slots.take?(queue.counted, queue.capacity)

  return true if Channel.send(queue.waiting, Entry(key: key, item: item), 0).ok?

  Slots.release(queue.counted)
  false
end

## The first item whose key has a place free, taken as running. When it skips items, the rest of the queue is read
## too, so all go back in their order. The item still counts as waiting until `started`.
def take[T](queue: Queue[T]) -> Optional[Entry[T]]
  # A scan holds the items it reads out of the channel and counts its probe of a key as running. Two scans at once
  # could each skip an item for the other's probe, or for a place that a worker gives back while the items are out of
  # the channel, and that worker would find it empty: all could leave with an item waiting. So one scan runs at a
  # time, and a worker that ends an item scans after any scan that was running then.
  while not Channel.send(queue.scanning, true, LOCK_WAIT_MS).ok?
  end

  scan = scan_once(queue)
  _ = Channel.recv(queue.scanning, 0)
  # A full queue on the way back would lose an accepted item: that is a bug, so it halts, once the lock is free.
  case scan.lost
    some(entry) -> Channel.send(queue.waiting, entry, 0).unwrap!
    none -> nil
  end

  scan.found
end

## The item that `take` gave is running now and no longer waits.
def started[T](queue: Queue[T]) -> Void
  Slots.release(queue.counted)
end

## An item that ran ends: its place of the key is free.
def finish[T](queue: Queue[T], key: String) -> Void
  ATS.add(queue.running, key, -1)
end

## Gives back an item that `take` gave and did not start. Its place in the queue was kept, so it always fits.
def put_back[T](queue: Queue[T], entry: Entry[T]) -> Void
  # A full queue here would lose an accepted post: that is a bug, so it halts.
  Channel.send(queue.waiting, entry, 0).unwrap!
end

private

# How long a `take` waits for the lock before it asks again (a scan takes far less).
LOCK_WAIT_MS = 1_000

# What one scan found, and the first item that did not fit back (never, unless the queue is broken).
struct Scan[T]
  found: Optional[Entry[T]]
  lost: Optional[Entry[T]]
end

def scan_once[T](queue: Queue[T]) -> Scan[T]
  others: List[Entry[T]] = []
  found: Optional[Entry[T]] = none
  for _ in 0...queue.capacity
    queued = Channel.recv(queue.waiting, 0)
    break if not queued.ok?

    entry = queued.unwrap!
    if found.none? and ATS.add(queue.running, entry.key, 1) <= queue.per_key
      found = some(entry)
      break if others.empty?
    elsif found.none?
      if queue.probe_pause_ms >= 0
        Task.sleep(queue.probe_pause_ms)
      end

      ATS.add(queue.running, entry.key, -1)
      others = others.push(entry)
    else
      others = others.push(entry)
    end
  end

  for entry in others
    return Scan(found: found, lost: some(entry)) if not Channel.send(queue.waiting, entry, 0).ok?
  end

  Scan(found: found, lost: none)
end

## A bounded queue of items that wait for a worker, with a limit of items running for one key. Tasks share it.

import Slots from "slots"

## The waiting items, and the running ones of each key.
struct Queue[T]
  waiting: Channel[Entry[T]]
  counted: ATS[String, Int]
  running: ATS[String, Int]
  capacity: Int
  per_key: Int
end

## An item with its key.
struct Entry[T]
  key: String
  item: T
end

## A new queue that holds `capacity` items, and lets `per_key` of one key run.
def new[T](capacity: Int, per_key: Int) -> Queue[T]
  waiting: Channel[Entry[T]] = Channel.new(capacity)
  Queue(waiting: waiting, counted: Slots.new(), running: Slots.new(), capacity: capacity, per_key: per_key)
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
  scan = scan_once(queue)
  return scan.found if scan.found.some? or not scan.skipped

  # Another taker's probe of a key may count as a running item and hide an item that fits, and a worker that sees the
  # channel empty while the skipped items are out of it leaves. Checking again after they are back wakes no one late.
  scan_once(queue).found
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

struct Scan[T]
  found: Optional[Entry[T]]
  skipped: Bool
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
      ATS.add(queue.running, entry.key, -1)
      others = others.push(entry)
    else
      others = others.push(entry)
    end
  end

  for entry in others
    put_back(queue, entry)
  end

  Scan(found: found, skipped: not others.empty?)
end

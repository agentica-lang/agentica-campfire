## A bounded queue of items that wait for a worker, with a limit of items running for one key. Tasks share it.

import Slots from "slots"

## The waiting items, and the running ones of each key.
struct Queue[T]
  waiting: Channel[Entry[T]]
  counted: ATS[String, Int]
  running: ATS[String, Int]
  numbers: ATS[String, Int]
  capacity: Int
  per_key: Int
end

## An item with its key. A number tells the order of arrival.
struct Entry[T]
  key: String
  number: Int
  item: T
end

## A new queue that holds `capacity` items, and lets `per_key` of one key run.
def new[T](capacity: Int, per_key: Int) -> Queue[T]
  waiting: Channel[Entry[T]] = Channel.new(capacity)
  Queue(
    waiting: waiting,
    counted: Slots.new(),
    running: Slots.new(),
    numbers: Slots.new(),
    capacity: capacity,
    per_key: per_key,
  )
end

## Adds an item at the back; false when the queue is full.
def offer[T](queue: Queue[T], key: String, item: T) -> Bool
  return false if not Slots.take?(queue.counted, queue.capacity)

  number = ATS.add(queue.numbers, NUMBER, 1)
  return true if Channel.send(queue.waiting, Entry(key: key, number: number, item: item), 0).ok?

  Slots.release(queue.counted)
  false
end

## The first item whose key has a place free, taken as running. The items of keys without a place wait out of the
## channel during the one pass, then go back in their order. The item still counts as waiting until `started`.
def take[T](queue: Queue[T]) -> Optional[Entry[T]]
  skipped: List[Entry[T]] = []
  found: Optional[Entry[T]] = none
  for _ in 0...queue.capacity
    queued = Channel.recv(queue.waiting, 0)
    break if not queued.ok?

    entry = queued.unwrap!
    if ATS.add(queue.running, entry.key, 1) <= queue.per_key
      found = some(entry)
      break
    end

    ATS.add(queue.running, entry.key, -1)
    skipped = skipped.push(entry)
  end

  for entry in skipped
    _ = put_back(queue, entry)
  end

  found
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
def put_back[T](queue: Queue[T], entry: Entry[T]) -> Bool = Channel.send(queue.waiting, entry, 0).ok?

private

NUMBER = "number"

import WorkQueue from "../src/campfire/work_queue"

private

def main() -> Void
  Test.run([
    Test.test("a put-back fits when the queue was full, and a new offer is refused meanwhile") do
      queue: WorkQueue.Queue[Int] = WorkQueue.new(2, 4)
      try Test.assert(WorkQueue.offer(queue, "a", 1), "first")
      try Test.assert(WorkQueue.offer(queue, "a", 2), "second")
      taken = WorkQueue.take(queue).unwrap!
      try Test.assert(not WorkQueue.offer(queue, "a", 3), "full while one is in hand")
      WorkQueue.finish(queue, taken.key)
      WorkQueue.put_back(queue, taken)
      try Test.eq(WorkQueue.take(queue).unwrap!.item, 2)
      Test.eq(WorkQueue.take(queue).unwrap!.item, 1)
    end,
    Test.test("a pass over posts of a capped key keeps their order") do
      queue: WorkQueue.Queue[Int] = WorkQueue.new(5, 1)
      for n in 1..4
        try Test.assert(WorkQueue.offer(queue, "a", n), "offer")
      end

      try Test.eq(WorkQueue.take(queue).unwrap!.item, 1)
      try Test.assert(WorkQueue.take(queue).none?, "the key is at its limit")
      WorkQueue.finish(queue, "a")
      try Test.eq(WorkQueue.take(queue).unwrap!.item, 2)
      WorkQueue.finish(queue, "a")
      try Test.eq(WorkQueue.take(queue).unwrap!.item, 3)
      WorkQueue.finish(queue, "a")
      Test.eq(WorkQueue.take(queue).unwrap!.item, 4)
    end,
    Test.test("a post that is taken ahead of skipped ones leaves them in their order") do
      queue: WorkQueue.Queue[Int] = WorkQueue.new(5, 1)
      try Test.assert(WorkQueue.offer(queue, "a", 1), "a1")
      try Test.eq(WorkQueue.take(queue).unwrap!.item, 1)
      try Test.assert(WorkQueue.offer(queue, "a", 2), "a2")
      try Test.assert(WorkQueue.offer(queue, "b", 3), "b3")
      try Test.assert(WorkQueue.offer(queue, "a", 4), "a4")
      try Test.eq(WorkQueue.take(queue).unwrap!.item, 3)
      WorkQueue.finish(queue, "a")
      try Test.eq(WorkQueue.take(queue).unwrap!.item, 2)
      WorkQueue.finish(queue, "a")
      Test.eq(WorkQueue.take(queue).unwrap!.item, 4)
    end,
    Test.test("workers that race on capped keys leave no item waiting") do
      # A worker that ended an item while another one's scan held the rest used to leave with them unread, in a few
      # races out of a hundred, so the race runs several times.
      race(64, 2, 6, -1, 10)
    end,
    Test.test("workers whose scans probe one capped key at once leave no item waiting") do
      # A pause between the probe of a key and its undo makes two scans see each other's probe and skip.
      race(4, 1, 3, 0, 200)
    end,
    Test.test("a worker that ends an item while a scan holds the rest takes one after that scan") do
      queue: WorkQueue.Queue[Int] = WorkQueue.new(4, 1)
      try Test.assert(WorkQueue.offer(queue, "a", 1), "a1")
      try Test.assert(WorkQueue.offer(queue, "a", 2), "a2")
      running = WorkQueue.take(queue).unwrap!
      WorkQueue.started(queue)
      # A scan in progress, as `take` makes it: the lock held and the item out of the channel.
      try Channel.send(queue.scanning, true, 0)
      held = try Channel.recv(queue.waiting, 0)
      worker = Task.spawn do
        WorkQueue.finish(queue, running.key)
        WorkQueue.take(queue)
      end

      waited = true
      case Task.await(worker, 50)
        Await.Done(_) -> waited = false
        Await.TimedOut -> nil
      end

      try Test.assert(waited, "the take of the worker did not wait for the scan")
      try Channel.send(queue.waiting, held, 0)
      _ = Channel.recv(queue.scanning, 0)
      Test.eq(Task.await(worker).map do |entry| entry.item end, some(2))
    end,
  ])
end

def drain(queue: WorkQueue.Queue[Int]) -> Result[Int]
  count = 0
  entry = WorkQueue.take(queue)
  while entry.some?
    count += 1
    WorkQueue.started(queue)
    WorkQueue.finish(queue, entry.unwrap!.key)
    entry = WorkQueue.take(queue)
  end

  ok(count)
end

# `rounds` races of `workers` that drain a queue of `items` over `keys` keys, one running per key, with the
# `probe_pause_ms` of the queue. Each must take every item.
def race(items: Int, keys: Int, workers: Int, probe_pause_ms: Int, rounds: Int) -> Result[Void]
  for round in 0...rounds
    queue: WorkQueue.Queue[Int] = WorkQueue.new(items, 1, probe_pause_ms)
    for n in 0...items
      try Test.assert(WorkQueue.offer(queue, "k#{n % keys}", n), "offer")
    end

    done = Task.map((0...workers).to_a, workers, 20_000) do |_| drain(queue) end
    taken = done.map(->(count) { count.unwrap_or(0) }).sum
    try Test.assert(taken == items, "round #{round}: #{taken} of #{items} items taken")
  end

  ok()
end

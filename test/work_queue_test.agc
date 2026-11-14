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
      try Test.assert(WorkQueue.put_back(queue, taken), "put back")
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
  ])
end

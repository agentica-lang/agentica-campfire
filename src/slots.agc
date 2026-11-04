## A limit on how many requests do slow work at once. The work here is hashing a password: `KDF.scrypt` takes about
## a second and 64 MiB, and the routes that hash are open to anyone, so without a limit a burst of sign-ins from a
## stranger fills the memory and the schedulers. A refused request is answered at once, and the work that is running
## is never cut short. A runtime halt inside the guarded call does not release its slot, so the guarded code must not
## halt (the callers keep to `Result` and never `unwrap!` there).

# The key of the one counter. An `ATS` table is the one value that request tasks can share and update atomically.
COUNT = "running"

# How long `wait?` sleeps between two tries.
RETRY_MS = 5

## A new set of slots, shared by every task that gets the handle.
export def new() -> ATS[String, Int]
  slots: ATS[String, Int] = ATS.new()
  return slots
end

## Takes a slot when fewer than `limit` are taken, and says whether it did. The caller that gets true must `release`.
export def take?(slots: ATS[String, Int], limit: Int) -> Bool
  if ATS.add(slots, COUNT, 1) <= limit
    return true
  end

  ATS.add(slots, COUNT, -1)
  return false
end

## Takes a slot like `take?`, but waits for one for up to `wait_ms` milliseconds, and says whether it got one. The wait
## sleeps between tries, so the scheduler is free for the task that holds the slot. With a limit of 1 this is a lock
## that the caller must `release`.
export def wait?(slots: ATS[String, Int], limit: Int, wait_ms: Int) -> Bool
  deadline = Time.monotonic_ms() + wait_ms
  while not take?(slots, limit)
    if Time.monotonic_ms() >= deadline
      return false
    end

    Task.sleep(RETRY_MS)
  end

  return true
end

## Gives a slot back.
export def release(slots: ATS[String, Int]) -> Void
  ATS.add(slots, COUNT, -1)
end

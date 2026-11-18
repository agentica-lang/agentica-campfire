import Jobs from "pkg/jobs/jobs"
import Logger from "std/logger"
import Consumers from "../src/campfire/consumers"

private

QUEUE = "work"
WAIT_MS = 5_000
LEASE_MS = 30_000
BACKOFF_MS = 1_000
GROUPS = 4
PER_GROUP = 6
LIMIT = 2

struct Started
  backend: Jobs.Backend
  clock: Jobs.Clock
end

def started() -> Result[Started]
  clock = Jobs.manual_clock()
  backend = try Jobs.memory(Jobs.MemoryOptions(clock: some(clock.now)))
  ok(Started(backend: backend, clock: clock))
end

def options(clock: Jobs.Clock, count: Int, max_per_group: Int) -> Consumers.Options
  Consumers.Options(
    fetch: Jobs.Fetch(queue: QUEUE, lease_ms: LEASE_MS, wait_ms: 1_000, max_per_group: max_per_group),
    count: count,
    clock: clock.now,
    backoff: ->(_) { BACKOFF_MS },
  )
end

def text_of(job: Jobs.Job) -> String = String.from_bytes(job.payload).unwrap_or("")

def end_all(given: Started, consumers: Consumers.Consumers) -> Void
  Jobs.close(given.backend, WAIT_MS)
  Consumers.stop(consumers, WAIT_MS)
end

# `ok` acks, `Jobs.discard` is dead at once, and another error runs again after the backoff and is dead on its last
# attempt; the log says which, with the fields of the job and never the text of its error.
def settles_by_the_rules() -> Result[Void]
  given = try started()
  for text in ["fine", "discard", "fail"]
    job = Jobs.NewJob(queue: QUEUE, payload: text.bytes, max_attempts: 2, meta: {"what": text})
    _ = try Jobs.enqueue(given.backend, job)
  end

  logged: Channel[Logger.Event] = Channel.new(16)
  _ = Logger.detach("console")
  try Logger.attach("test", Logger.Level.Warning) do |event| _ = logged.send(event, WAIT_MS) end
  consumers = Consumers.start(given.backend, options(given.clock, 1, 0)) do |job| outcome(job) end
  first = try logged.recv(WAIT_MS)
  second = try logged.recv(WAIT_MS)
  given.clock.advance.call(BACKOFF_MS)
  last = try logged.recv(WAIT_MS)
  end_all(given, consumers)
  _ = Logger.detach("test")
  try Test.eq(
    [first.message, first.fields.get("what", ""), first.fields.get("reason", ""), first.fields.get("cause", "")],
    ["job dead", "discard", "discarded", "jobs.discard"],
  )

  try Test.eq(
    [second.message, second.fields.get("what", ""), second.fields.get("attempt", "")],
    ["job failed, it will run again", "fail", "1"],
  )

  try Test.eq(
    [last.message, last.fields.get("reason", ""), last.fields.get("attempt", "")],
    ["job dead", "attempts_exhausted", "2"],
  )

  Test.assert(not "#{first.fields}".include?("no such"), "the text of an error is in the log")
end

def outcome(job: Jobs.Job) -> Result[Void]
  text = text_of(job)
  return Jobs.discard("no such address") if text == "discard"
  return error("no such host") if text == "fail"

  ok()
end

# A consumer that stops in the middle of a job loses its lease, and the job comes back to another one when the lease
# runs out.
def cancelled_job_comes_back() -> Result[Void]
  given = try started()
  _ = try Jobs.enqueue(given.backend, Jobs.NewJob(queue: QUEUE, payload: "a".bytes))
  attempts: Channel[Int] = Channel.new(4)
  never: Channel[Bool] = Channel.new(1)
  first = Consumers.start(given.backend, options(given.clock, 1, 0)) do |job|
    _ = attempts.send(job.attempt, WAIT_MS)
    _ = never.recv(LEASE_MS)
    ok()
  end

  try Test.eq(try attempts.recv(WAIT_MS), 1)
  Consumers.stop(first, 1)
  given.clock.advance.call(LEASE_MS + 1)
  second = Consumers.start(given.backend, options(given.clock, 1, 0)) do |job|
    _ = attempts.send(job.attempt, WAIT_MS)
    ok()
  end

  again = attempts.recv(WAIT_MS)
  end_all(given, second)
  Test.eq(try again, 2)
end

# Many groups with more jobs than their limit, and more consumers than the limit: each job runs once, and a group
# never has more than its limit under way.
def every_job_once_within_the_limit() -> Result[Void]
  given = try started()
  jobs = (0...(GROUPS * PER_GROUP)).to_a.map do |n|
    Jobs.NewJob(queue: QUEUE, payload: n.to_s.bytes, group: some("g#{n % GROUPS}"))
  end

  _ = try Jobs.enqueue_all(given.backend, jobs)
  running: ATS[String, Int] = ATS.new()
  seen: ATS[String, Int] = ATS.new()
  done: Channel[Bool] = Channel.new(GROUPS * PER_GROUP)
  consumers = Consumers.start(given.backend, options(given.clock, GROUPS * LIMIT, LIMIT)) do |job|
    group = job.group.unwrap_or("")
    if running.add(group, 1) > LIMIT
      _ = running.add("over", 1)
    end

    _ = running.add(group, -1)
    _ = seen.add(text_of(job), 1)
    done.send(true, WAIT_MS)
  end

  received = 0
  while received < GROUPS * PER_GROUP and done.recv(WAIT_MS).ok?
    received += 1
  end

  end_all(given, consumers)
  try Test.eq(received, GROUPS * PER_GROUP)
  try Test.eq(seen.size, GROUPS * PER_GROUP)
  try Test.assert(seen.keys.all? do |key| seen.get(key).unwrap_or(0) == 1 end, "a job ran twice")
  Test.eq(running.get("over").unwrap_or(0), 0)
end

# A job that must not run twice is dead when its handler crashes, not run again.
def crash_is_dead_without_retry() -> Result[Void]
  given = try started()
  _ = try Jobs.enqueue(given.backend, Jobs.NewJob(queue: QUEUE, payload: "a".bytes))
  logged: Channel[Logger.Event] = Channel.new(4)
  _ = Logger.detach("console")
  try Logger.attach("crash", Logger.Level.Warning) do |event| _ = logged.send(event, WAIT_MS) end
  once = options(given.clock, 1, 0).with(retry_crashes: false)
  consumers = Consumers.start(given.backend, once) do |job|
    # A job with no group: the unwrap crashes the handler.
    _ = job.group.unwrap!
    ok()
  end

  event = logged.recv(WAIT_MS)
  end_all(given, consumers)
  _ = Logger.detach("crash")
  dead = try event
  fields = dead.fields
  Test.eq([dead.message, fields.get("reason", ""), fields.get("cause", "")], ["job dead", "crashed", "task.crashed"])
end

# A fetch that waits for a full group is woken when the lease of that group ends, long before its `wait_ms`.
def full_group_wakes_its_waiting_fetch() -> Result[Void]
  given = try started()
  for text in ["first", "second"]
    _ = try Jobs.enqueue(given.backend, Jobs.NewJob(queue: QUEUE, payload: text.bytes, group: some("g")))
  end

  ran: Channel[String] = Channel.new(4)
  release: Channel[Bool] = Channel.new(1)
  waiting = options(given.clock, 2, 1)
  slow = waiting.with(fetch: waiting.fetch.with(wait_ms: 60_000))
  consumers = Consumers.start(given.backend, slow) do |job|
    _ = ran.send(text_of(job), WAIT_MS)
    if text_of(job) == "first"
      _ = try release.recv(WAIT_MS)
    end

    ok()
  end

  first = ran.recv(WAIT_MS)
  _ = release.send(true, WAIT_MS)
  second = ran.recv(WAIT_MS)
  end_all(given, consumers)
  try Test.eq(try first, "first")
  Test.eq(try second, "second")
end

def main() -> Void
  Test.run([
    Test.test("a job is acked, dead or run again by the rules of Jobs.drain, and the log says which") do
      settles_by_the_rules()
    end,
    Test.test("the job of a consumer stopped in the middle comes back to another one after its lease") do
      cancelled_job_comes_back()
    end,
    Test.test("every job of many groups runs once, and no group has more than its limit under way") do
      every_job_once_within_the_limit()
    end,
    Test.test("a crash of a handler that must not run twice makes its job dead") do crash_is_dead_without_retry() end,
    Test.test("a fetch that waits for a full group is woken when the group's lease ends") do
      full_group_wakes_its_waiting_fetch()
    end,
  ])
end

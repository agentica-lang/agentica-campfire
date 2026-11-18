## The tasks that run the jobs of one queue (the `jobs` package). Each task fetches one job, runs the handler in a task
## of its own, so that a crash is an `error` and never ends the consumer, then settles the job by the rules of
## `Jobs.drain`: `ok` acks it, `Jobs.discard` makes it dead, and another error runs it again after `backoff` of its
## attempt, or makes it dead on its last attempt. A job that will run again is a `warning` in the log and a dead one an
## `err` (with `reason`: `discarded` or `attempts_exhausted`); the fields are the queue, the id, the attempt, the group
## and the `meta` of the job, never its payload or the text of its error. The tasks end when the backend is closed.

import Jobs from "pkg/jobs/jobs"
import Logger from "std/logger"

## How the consumers of a queue fetch, how many there are, and when a failed job runs again: `clock` is the clock of the
## backend and `backoff` gives the wait in ms from the attempt.
struct Options
  fetch: Jobs.Fetch
  count: Int
  clock: Fn[Int]
  backoff: Fn[Int, Int]
end

## The tasks of a queue, for `stop`.
struct Consumers
  tasks: List[Task[Result[Void]]]
end

## Starts `options.count` consumers of `options.fetch.queue` in the caller, which must live as long as they run.
def start(backend: Jobs.Backend, options: Options, handle: Fn[Jobs.Job, Result[Void]]) -> Consumers
  consumer = Consumer(backend: backend, options: options, handle: handle)
  Consumers(tasks: (0...options.count).to_a.map do |_| Task.spawn(&consume, consumer) end)
end

## Waits up to `wait_ms` in all for the consumers to end, which they do once the backend is closed (`Jobs.close`) and
## their job is settled, then cancels the ones still running. The job of a cancelled consumer comes back when its lease
## runs out.
def stop(consumers: Consumers, wait_ms: Int) -> Void
  deadline = Time.monotonic_ms() + wait_ms
  for task in consumers.tasks
    left = deadline - Time.monotonic_ms()
    if left < 1
      Task.cancel(task)
      next
    end

    case Task.await(task, left)
      Await.Done(_) -> nil
      Await.TimedOut -> Task.cancel(task)
    end
  end
end

private

struct Consumer
  backend: Jobs.Backend
  options: Options
  handle: Fn[Jobs.Job, Result[Void]]
end

struct Run
  handle: Fn[Jobs.Job, Result[Void]]
  job: Jobs.Job
end

def consume(consumer: Consumer) -> Result[Void]
  while true
    fetched = Jobs.fetch(consumer.backend, consumer.options.fetch)
    case fetched
      error(e) if e.is_a?("jobs.closed") -> return ok()
      error(e) if e.is_a?("jobs.timeout") -> next
      error(e) ->
        Logger.err("job fetch failed", {"queue": consumer.options.fetch.queue, "kind": e.kind})
        return error(e)
      ok(leases) ->
        for lease in leases
          settle(consumer, lease)
        end
    end
  end

  ok()
end

def settle(consumer: Consumer, lease: Jobs.Lease) -> Void
  job = lease.job
  result = Task.await(Task.spawn(&run, Run(handle: consumer.handle, job: job)))
  fields = fields_of(job)
  settled = case result
    ok(_) -> Jobs.ack(consumer.backend, lease)
    error(e) if e.is_a?("jobs.discard") ->
      Logger.err("job dead", fields.put("reason", "discarded"))
      Jobs.nack(consumer.backend, lease, Jobs.Nack.Dead(e.message))
    error(e) if job.attempt >= job.max_attempts ->
      Logger.err("job dead", fields.put("reason", "attempts_exhausted"))
      Jobs.nack(consumer.backend, lease, Jobs.Nack.Dead(e.message))
    error(e) ->
      Logger.warning("job failed, it will run again", fields)
      at = consumer.options.clock.call() + consumer.options.backoff.call(job.attempt)
      Jobs.nack(consumer.backend, lease, Jobs.Nack.Retry(Jobs.Later(at_ms: at, error: some(e.message))))
  end

  case settled
    error(e) if not e.is_a?("jobs.closed") -> Logger.warning("job not settled", fields.put("kind", e.kind))
    _ -> nil
  end
end

def run(given: Run) -> Result[Void] = given.handle.call(given.job)

def fields_of(job: Jobs.Job) -> Map[String, String]
  given = {"queue": job.queue, "id": job.id, "attempt": job.attempt.to_s}
  fields = job.meta.keys.reduce(given) do |acc, name| acc.put(name, job.meta.get(name, "")) end
  case job.group
    some(group) -> fields.put("group", group)
    none -> fields
  end
end

## The task that deletes the messages of a room that `Rooms.destroy_later` has taken away from its people, and then the
## room (`Room::DestroyJob` of Rails). It takes a connection of the pool for each message and gives it back before the
## next, so the requests of other people are served in between: a task that kept one connection for a whole room would
## take it from the pool for as long as that lasts.
##
## A step that fails because the database is busy (no free connection in time, `database is locked` once its busy
## timeout is over) is tried again a few times with a longer pause each time (`retry`); any other failure, or the last
## of the busy ones, is logged and ends the task. So does a restart of the app. What is left of the room is then closed,
## with nobody in it and the rest of its messages in the database; nothing sweeps it yet.

import Database from "../campfire/repo/database"
import Rooms from "../campfire/rooms"

## Starts the task for the room and gives it. It does not wait; the task logs a failure and ends. The handle is for a
## caller that wants to wait for the end (a spec); a request does not.
def start(pool: Database.Pool, room_id: Int) -> Task[Result[Void]]
  Task.spawn(&run, Job(pool: pool, room_id: room_id))
end

## Runs `step`, and again after a pause of `pause_ms` times the number of the try while it fails because the database is
## busy, up to `attempts` tries in all. It gives the last result. A failure that is not a busy one is not tried again
## (it would fail the same), and neither is a pool that is closed, which is the app stopping.
def retry[R](attempts: Int, pause_ms: Int, step: Fn[Result[R]]) -> Result[R]
  done = step.call()
  tries = 1
  while not done.ok? and tries < attempts and transient?(done.message)
    Task.sleep(pause_ms * tries)
    tries += 1
    done = step.call()
  end

  done
end

private

# How many times a step is tried, and the pause after the first failure; the pause grows with each try (100, 200, 300
# and 400 milliseconds, a second in all). Each try can also wait on its own, for a connection of the pool
# (`CAMPFIRE_DB_CHECKOUT_MS`) or for the busy timeout of SQLite, so a step that never works gives up after a second of
# pauses plus the waits of its five tries.
ATTEMPTS = 5
PAUSE_MS = 100

struct Job
  pool: Database.Pool
  room_id: Int
end

def transient?(message: String) -> Bool = Database.busy?(message) and not message.include?("pool error: closed")

def run(job: Job) -> Result[Void]
  done = delete_all(job)
  if not done.ok?
    IO.warn("campfire: deleting the room #{job.room_id} stopped, what is left of it stays: #{done.message}")
  end

  done
end

def delete_all(job: Job) -> Result[Void]
  more = true
  while more
    more = try retry(ATTEMPTS, PAUSE_MS) do next_message(job) end
  end

  retry(ATTEMPTS, PAUSE_MS) do last_step(job) end
end

def next_message(job: Job) -> Result[Bool]
  Database.with_connection(job.pool) do |db| Rooms.delete_next_message(db, job.room_id) end
end

def last_step(job: Job) -> Result[Void]
  Database.with_connection(job.pool) do |db| Rooms.delete_room(db, job.room_id) end
end

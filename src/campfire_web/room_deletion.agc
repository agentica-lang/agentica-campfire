## The task that deletes the messages of a room that `Rooms.destroy_later` has taken away from its people, and then the
## room (`Room::DestroyJob` of Rails). It takes a connection of the pool for each message and gives it back before the
## next, so the requests of other people are served in between: a task that kept one connection for a whole room would
## take it from the pool for as long as that lasts. If the app stops, or a statement fails, the task ends with what is
## left of the room (closed, with nobody in it) in the database; nothing sweeps it yet.

import Database from "../campfire/repo/database"
import Rooms from "../campfire/rooms"

struct Job
  pool: Database.Pool
  room_id: Int
end

## Starts the task for the room and gives it. It does not wait; the task logs a failure and ends. The handle is for a
## caller that wants to wait for the end (a spec); a request does not.
export def start(pool: Database.Pool, room_id: Int) -> Task[Result[Void]]
  return Task.spawn(&run, Job(pool: pool, room_id: room_id))
end

def run(job: Job) -> Result[Void]
  done = delete_all(job)
  if not done.ok?
    IO.warn("campfire: deleting the room #{job.room_id} stopped: #{done.message}")
  end

  return done
end

def delete_all(job: Job) -> Result[Void]
  more = true
  while more
    more = try Database.with_connection(job.pool) do |db| Rooms.delete_next_message(db, job.room_id) end
  end

  return Database.with_connection(job.pool) do |db| Rooms.delete_room(db, job.room_id) end
end

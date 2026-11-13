## The task that takes the messages of a banned person away (`RemoveBannedContentJob` of Rails) and tells the people who
## are looking at each room that the message is gone. It takes a connection of the pool for each message and gives it
## back before the next, as `RoomDeletion` does, so the requests of other people are served in between. A failure that
## is not a busy database is logged and ends the task; what is left stays in the database.

import Database from "../campfire/repo/database"
import Bans from "../campfire/bans"
import CableWeb from "cable"
import RoomDeletion from "room_deletion"

## Starts the task for the person and gives it. It does not wait; the task logs a failure and ends. The handle is for a
## caller that wants to wait for the end (a spec); a request does not.
def start(pool: Database.Pool, cable: CableWeb.Cable, user_id: Int) -> Task[Result[Void]]
  Task.spawn(&run, Job(pool: pool, cable: cable, user_id: user_id))
end

private

ATTEMPTS = 5
PAUSE_MS = 100

struct Job
  pool: Database.Pool
  cable: CableWeb.Cable
  user_id: Int
end

def run(job: Job) -> Result[Void]
  done = remove_all(job)
  if not done.ok?
    IO.warn("campfire: removing the messages of person #{job.user_id} stopped, what is left stays: #{done.message}")
  end

  done
end

def remove_all(job: Job) -> Result[Void]
  more = true
  while more
    gone = try RoomDeletion.retry(ATTEMPTS, PAUSE_MS) do next_message(job) end
    more = gone.some?
    if more
      CableWeb.message_removed(job.cable, gone.unwrap!.room_id, gone.unwrap!.message_id)
    end
  end

  ok()
end

def next_message(job: Job) -> Result[Optional[Bans.Gone]]
  Database.with_connection(job.pool) do |db| Bans.delete_next_message(db, job.user_id) end
end

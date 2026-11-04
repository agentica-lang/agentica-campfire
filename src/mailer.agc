## The mailer: a task that sends the messages the app hands to it, so a slow or dead mail server never holds up a
## request. The app calls `enqueue`, which never waits: it puts the message in a bounded queue and goes on, and the
## task takes the messages one at a time and sends each with `Smtp.send`. A message that cannot be sent is logged, with
## the count of its recipients and the summary of the error (`Smtp.error_summary`: no server text, no address, no
## password), and dropped; nothing here retries, since the one message of today is a link that a person asks for again.
## With no `Smtp.Options` there is no task, and `enqueue` says no.

import Smtp from "smtp"

# How long the task waits for a message before it looks at the queue again, and how long `stop` waits for it to
# finish what is queued before it gives up on it.
IDLE_MS = 1_000
STOP_WAIT_MS = 10_000

## A mailer. `queue` and `worker` are `none` when email is off.
export struct Mailer
  queue: Optional[Channel[Smtp.Message]]
  capacity: Int
  worker: Optional[Task[Result[Void]]]
end

struct Job
  queue: Channel[Smtp.Message]
  options: Smtp.Options
end

## Starts the task for these options, or a mailer that sends nothing for `none`. `capacity` is how many messages may
## wait: they are the links that people ask for, one at a time for each person and five minutes apart, so a queue that
## fills up means a mail server that is down, and the next messages are dropped, not held. It belongs to the task that
## calls it, and the task that it starts owns its queue: if it ever crashes, the queue closes and `enqueue` finds out.
export def start(options: Optional[Smtp.Options], capacity: Int) -> Mailer
  case options
    none -> return Mailer(queue: none, capacity: 0, worker: none)
    some(chosen) ->
      queue: Channel[Smtp.Message] = Channel.new(capacity)
      worker = Task.spawn_owning(&work, Job(queue: queue, options: chosen))
      return Mailer(queue: some(queue), capacity: capacity, worker: some(worker))
  end
end

## One line for the start-up output that says where mail goes, or that it is off. It never has the user or the
## password.
export def status(options: Optional[Smtp.Options]) -> String
  case options
    none -> return "mail: off (CAMPFIRE_SMTP_URL is not set, so no email is sent)"
    some(chosen) -> return "mail: sending through #{chosen.host}:#{chosen.port} (#{security_name(chosen.security)})"
  end
end

## True when the app can send email: there is a task and its queue is open. A task that crashed has closed it, so the
## pages that need email are not offered after that.
export def enabled?(mailer: Mailer) -> Bool
  case mailer.queue
    none -> return false
    some(queue) -> return not Channel.closed?(queue)
  end
end

## Hands the message to the task and gives true, or gives false (and logs why) when there is no task, the queue is full
## or the task has stopped. It never waits and never fails the caller: the page that asks for an email does not change
## with the outcome.
export def enqueue(mailer: Mailer, message: Smtp.Message) -> Bool
  case mailer.queue
    none -> return false
    some(queue) ->
      sent = Channel.send(queue, message, 0)
      if sent.ok?
        return true
      end

      if Channel.closed?(queue)
        IO.warn("campfire: mail: a message was dropped, since the mailer has stopped")
      else
        IO.warn("campfire: mail: a message was dropped, since #{mailer.capacity} are waiting to be sent")
      end

      return false
  end
end

## Sends what is queued and ends the task, waiting for it up to ten seconds (a mail server that does not answer is cut
## off then). A task that crashed is not an error here: its crash was reported when it happened. The mailer may not be
## used after this.
export def stop(mailer: Mailer) -> Void
  case mailer.queue
    none -> return
    some(queue) -> Channel.close(queue)
  end

  case mailer.worker
    none -> return
    some(worker) ->
      # The task returns a `Result`, so that a crash is an `error` here and not a halt of the caller.
      case Task.await(worker, STOP_WAIT_MS)
        Await.Done(_) -> return
        Await.TimedOut -> give_up(worker, mailer.queue)
      end
  end
end

# The task did not finish in time: it is cut off, and the messages that still wait are counted and dropped (the
# one that
# it was sending is lost too). Nothing can be said of the recipients, which may be more than one a message.
def give_up(worker: Task[Result[Void]], queue: Optional[Channel[Smtp.Message]]) -> Void
  Task.cancel(worker)
  waiting = 0
  case queue
    none -> waiting = 0
    some(open) ->
      while Channel.recv(open, 0).ok?
        waiting += 1
      end
  end

  IO.warn(
    "campfire: mail: the mailer was stopped while it was sending, " +
    "so that message and #{waiting} waiting ones were dropped",
  )
end

# Takes messages until the queue is closed and empty. A timeout of the wait is not the end: the loop only stops when
# `stop` closed the queue (or the owner of it ended).
def work(job: Job) -> Result[Void]
  running = true
  while running
    case Channel.recv(job.queue, IDLE_MS)
      ok(message) -> deliver(job.options, message)
      error(_) -> running = not (Channel.closed?(job.queue) and Channel.empty?(job.queue))
    end
  end

  return ok()
end

def deliver(options: Smtp.Options, message: Smtp.Message) -> Void
  sent = Smtp.send(message, options)
  if sent.ok?
    return
  end

  count = message.to.size + message.cc.size + message.bcc.size
  noun = "recipients"
  if count == 1
    noun = "recipient"
  end

  IO.warn("campfire: mail: a message to #{count} #{noun} was not sent: #{Smtp.error_summary(sent.message)}")
end

def security_name(security: Smtp.Security) -> String
  case security
    Smtp.Security.Starttls -> return "STARTTLS"
    Smtp.Security.Implicit -> return "TLS"
    Smtp.Security.Plain -> return "plain"
  end
end

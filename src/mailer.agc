## The mailer: a task that sends the messages the app hands to it, so a slow or dead mail server never holds up a
## request. The app calls `enqueue`, which never waits: it puts the message in a bounded queue and goes on, and the task
## takes the messages one at a time and sends each with `Smtp.send`. A message that cannot be sent is logged, with the
## count of its recipients and the error of the server (which has no password), and dropped; nothing here retries, since
## the one message of today is a link that a person asks for again. With no `Smtp.Options` there is no task, and
## `enqueue` says no.

import Smtp from "smtp"

# The messages that may wait for the task. The only ones are the links that people ask for, one a minute for each
# person, so a queue that fills up means a mail server that is down: the next messages are dropped, not held.
MAX_QUEUED = 32

# How long the task waits for a message before it looks at the queue again, and how long `stop` waits for it to
# finish what is queued before it gives up on it.
IDLE_MS = 1_000
STOP_WAIT_MS = 10_000

## A mailer. `queue` and `worker` are `none` when email is off.
export struct Mailer
  queue: Optional[Channel[Smtp.Message]]
  worker: Optional[Task[Void]]
end

struct Job
  queue: Channel[Smtp.Message]
  options: Smtp.Options
end

## Starts the task for these options, or a mailer that sends nothing for `none`. It belongs to the task that calls it,
## and the task that it starts owns its queue: if it ever crashes, the queue closes and `enqueue` finds out.
export def start(options: Optional[Smtp.Options]) -> Mailer
  case options
    none -> return Mailer(queue: none, worker: none)
    some(chosen) ->
      queue: Channel[Smtp.Message] = Channel.new(MAX_QUEUED)
      worker = Task.spawn_owning(&work, Job(queue: queue, options: chosen))
      return Mailer(queue: some(queue), worker: some(worker))
  end
end

## One line for the start-up output that says where mail goes, or that it is off. It never has the user or the password.
export def status(options: Optional[Smtp.Options]) -> String
  case options
    none -> return "mail: off (CAMPFIRE_SMTP_URL is not set, so no email is sent)"
    some(chosen) -> return "mail: sending through #{chosen.host}:#{chosen.port} (#{security_name(chosen.security)})"
  end
end

## True when the app can send email.
export def enabled?(mailer: Mailer) -> Bool
  return mailer.queue.some?
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
        IO.warn("campfire: mail: a message was dropped, since #{MAX_QUEUED} are waiting to be sent")
      end

      return false
  end
end

## Sends what is queued and ends the task, waiting for it up to ten seconds (a mail server that does not answer is cut
## off then). The task may not be used after this.
export def stop(mailer: Mailer) -> Void
  case mailer.queue
    none -> return
    some(queue) -> Channel.close(queue)
  end

  case mailer.worker
    none -> return
    some(worker) ->
      case Task.await(worker, STOP_WAIT_MS)
        Await.Done(_) -> return
        Await.TimedOut -> Task.cancel(worker)
      end
  end
end

# Takes messages until the queue is closed and empty. A timeout of the wait is not the end: the loop only stops when
# `stop` closed the queue (or the owner of it ended).
def work(job: Job) -> Void
  running = true
  while running
    case Channel.recv(job.queue, IDLE_MS)
      ok(message) -> deliver(job.options, message)
      error(_) -> running = not (Channel.closed?(job.queue) and Channel.empty?(job.queue))
    end
  end
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

  IO.warn("campfire: mail: a message to #{count} #{noun} was not sent: #{sent.message}")
end

def security_name(security: Smtp.Security) -> String
  case security
    Smtp.Security.Starttls -> return "STARTTLS"
    Smtp.Security.Implicit -> return "TLS"
    Smtp.Security.Plain -> return "plain"
  end
end

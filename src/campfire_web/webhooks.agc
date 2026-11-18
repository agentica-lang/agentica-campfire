## The webhooks of the chat bots (Rails' `Webhook`, `Bot::WebhookJob` and `MessagesController#deliver_webhooks_to_bots`).
## After a person posts a message, the request adds a job to the queue `FAN_OUT` (the `jobs` package, in memory) and
## does not wait. A consumer of that queue finds the bots the message is meant for (`Bots.webhooks_for`: every bot of a
## direct room, the mentioned bots of another room, never the author; at most `MAX_HOOKS`) and adds one job per bot to
## the queue `POST`, whose consumers post the JSON of Rails to each webhook URL. A job holds ids only, as Rails' job
## holds records: the room, the message and the webhook are read again when it runs, so the key of a bot is never in a
## queue, and a job whose bot, webhook or message is gone is dropped. A message that a bot posts through the API goes to
## no webhook, so two bots cannot answer each other forever. An answer `200` with `text/html` or `text/plain` is posted
## back to the room as a message of the bot, and an answer that takes longer than `CAMPFIRE_WEBHOOK_TIMEOUT` is
## answered with Rails' "Failed to respond within N seconds". A reply never goes to the webhooks again. A connection
## that fails before anything is sent (refused, or a host that does not resolve) is tried again, `ATTEMPTS` times in
## all, `PAUSE_MS` times the attempt later; anything else, a crash included, is dropped, since the webhook may have got
## the post. A job given up is logged (`Consumers`) with a fixed cause, the kind of its error (`jobs.discard.bot_gone`,
## `webhook.refused`...). At most `MAX_RUNNING` posts run at once, and at most `MAX_PER_BOT` for one bot (the bot is the
## `group` of its jobs), so a slow bot cannot take every consumer; at most `MAX_WAITING` more wait, and a message past
## that is logged and dropped. The two queues have their places apart, so messages that wait to be fanned out never
## take the places of the posts. `App.start` starts the queues and `App.stop` stops them; a post under way when they
## stop is lost.
##
## A webhook reaches only an address of the open internet (`Bans.public_address?`): every address that its host
## resolves to must be one, unless `CAMPFIRE_WEBHOOK_PRIVATE_ADDRESSES` is true. Rails does not check this (an
## administrator sets the URL); here a bot form cannot reach the services next to the app by default. The check comes
## before the post, which resolves the host again, so a name whose DNS changes in between is not caught
## (agentica-lang/agentica#1556).

import Db from "pkg/db/db"
import HTTP from "std/http"
import Jobs from "pkg/jobs/jobs"
import Logger from "std/logger"
import Bans from "../campfire/bans"
import Bots from "../campfire/bots"
import CableWeb from "cable"
import Consumers from "../campfire/consumers"
import Database from "../campfire/repo/database"
import HtmlSanitizer from "../campfire/html_sanitizer"
import Mentions from "../campfire/mentions"
import Rooms from "../campfire/rooms"
import Routes from "routes"
import {Config} from "../campfire/config"

## The queue of the messages to fan out to their bots, and the queue of the posts, one per message and bot.
FAN_OUT = "webhooks.fan_out"
POST = "webhooks.post"

## What the jobs need: `posts` is the queue that a fan-out fills.
struct Delivery
  posts: Jobs.Backend
  pool: Database.Pool
  cable: CableWeb.Cable
  timeout_ms: Int
  private_addresses: Bool
  max_message_length: Int
end

## The queues and their consumers, from `start` to `stop`.
struct Hooks
  fan_out: Jobs.Backend
  delivery: Delivery
  fan_outs: Consumers.Consumers
  posts: Consumers.Consumers
end

## For tests: `clock` is the time of the queues (a clock that never goes back by default), and `consumers: false`
## starts none, so a test runs the jobs itself (`Jobs.drain` with `backend`, `handler` and `backoff`).
struct Options
  clock: Optional[Fn[Int]] = none
  consumers: Bool = true
end

## Starts the queues and their consumers in the caller, which must live as long as the app does.
def start(config: Config, pool: Database.Pool, cable: CableWeb.Cable, options: Options = Options()) -> Result[Hooks]
  clock = options.clock.unwrap_or(steady_clock())
  fan_out = try Jobs.memory(Jobs.MemoryOptions(max_jobs: MAX_WAITING, clock: some(clock)))
  started = Jobs.memory(Jobs.MemoryOptions(max_jobs: MAX_WAITING + MAX_RUNNING, clock: some(clock)))
  if not started.ok?
    Jobs.close(fan_out, CLOSE_MS)
    return error(started.message)
  end

  delivery = Delivery(
    posts: started.unwrap!,
    pool: pool,
    cable: cable,
    timeout_ms: config.webhook_timeout_ms,
    private_addresses: config.webhook_private_addresses,
    max_message_length: config.max_message_length,
  )

  none_running = Consumers.Consumers(tasks: [])
  hooks = Hooks(fan_out: fan_out, delivery: delivery, fan_outs: none_running, posts: none_running)
  return ok(hooks) if not options.consumers

  fan_outs = Consumers.Options(
    fetch: Jobs.Fetch(queue: FAN_OUT, lease_ms: lease_ms(config), wait_ms: WAIT_MS),
    count: FAN_OUTS,
    clock: clock,
    backoff: &backoff,
  )

  posts = Consumers.Options(
    fetch: Jobs.Fetch(queue: POST, lease_ms: lease_ms(config), wait_ms: WAIT_MS, max_per_group: MAX_PER_BOT),
    count: MAX_RUNNING,
    clock: clock,
    backoff: &backoff,
    retry_crashes: false,
  )

  ok(
    hooks.with(
      fan_outs: Consumers.start(fan_out, fan_outs, handler(delivery, FAN_OUT)),
      posts: Consumers.start(delivery.posts, posts, handler(delivery, POST)),
    ),
  )
end

## Closes the queues and waits a little for the consumers; the jobs that wait are dropped.
def stop(hooks: Hooks) -> Void
  Jobs.close(hooks.fan_out, CLOSE_MS)
  Jobs.close(hooks.delivery.posts, CLOSE_MS)
  Consumers.stop(hooks.fan_outs, STOP_MS)
  Consumers.stop(hooks.posts, STOP_MS)
end

## Queues the delivery of a new message of a person to the bots it is meant for and does not wait. The caller has given
## its database connection back. A message with no mention in a room that is not direct is meant for nobody and queues
## nothing.
def deliver_later(hooks: Hooks, room: Rooms.Room, message: Rooms.Message) -> Void
  return if room.room_type != Rooms.DIRECT and Mentions.ids(message.body).empty?

  job = Jobs.json(FAN_OUT, FanOut(room_id: room.id, message_id: message.id)).with(
    max_attempts: ATTEMPTS,
    unique_key: some(message.id.to_s),
    meta: {"message_id": message.id.to_s},
  )

  case Jobs.enqueue(hooks.fan_out, job)
    error(e) -> Logger.warning("webhooks dropped", {"message_id": message.id.to_s, "kind": e.kind})
    ok(_) -> nil
  end
end

## The backend of a queue, `FAN_OUT` or `POST`.
def backend(hooks: Hooks, queue: String) -> Jobs.Backend
  return hooks.fan_out if queue == FAN_OUT

  hooks.delivery.posts
end

## How long the lease of a job lasts. It covers one attempt, since each attempt gets a lease of its own: two blocks of
## the pool, the reads and the reply's write (each a checkout of up to `db_checkout_ms` and a block of up to
## `Database.BLOCK_MS`, whatever busy timeout the database URL sets), the lookup of the host and the post (each up to
## the webhook timeout), and a margin. A lease that ended while the post was under way would send the post again.
def lease_ms(config: Config) -> Int
  2 * (config.db_checkout_ms + Database.BLOCK_MS) + 2 * config.webhook_timeout_ms + LEASE_MARGIN_MS
end

## What runs the jobs of a queue.
def handler(delivery: Delivery, queue: String) -> Fn[Jobs.Job, Result[Void]]
  return ->(job) { fan_out(delivery, job) } if queue == FAN_OUT

  ->(job) { post(delivery, job) }
end

## How long a post whose connection failed waits before its next attempt.
def backoff(attempt: Int) -> Int = PAUSE_MS * attempt

private

MAX_RUNNING = 32
MAX_WAITING = 256
MAX_HOOKS = 16
MAX_PER_BOT = 4
# A fan-out waits for a connection of the pool, so one slow checkout does not hold up the next messages.
FAN_OUTS = 4
ATTEMPTS = 3
PAUSE_MS = 500
# A fetch waits this long for a job before it asks again.
WAIT_MS = 5_000
LEASE_MARGIN_MS = 10_000
CLOSE_MS = 1_000
STOP_MS = 2_000
# The most of an answer that is read.
MAX_ANSWER_BYTES = 1_048_576
TIMED_OUT = "network: operation timed out"
NOT_CONNECTED = "network: connection failed"
NOT_FOUND = "network: host not found"
TEXT_TYPES = ["text/html", "text/plain"]
# Each reply is a new message, with a client id of its own.
CLIENT_ID_BYTES = 16

struct FanOut
  room_id: Int
  message_id: Int
end

struct PostJob
  room_id: Int
  message_id: Int
  bot_id: Int
end

## One message for one bot, read again from the ids of its job.
struct Post
  room: Rooms.Room
  message: Rooms.Message
  text: String
  hook: Bots.Hook
end

# The JSON of Rails' `Webhook#payload`. A direct room has no name (`null`).
struct Payload
  user: Author
  room: RoomRef
  message: MessageRef
end

struct Author
  id: Int
  name: String
end

struct RoomRef
  id: Int
  name: Optional[String]
  path: String
end

struct MessageRef
  id: Int
  body: Body
  path: String
end

struct Body
  html: String
  plain: String
end

def fan_out(delivery: Delivery, job: Jobs.Job) -> Result[Void]
  given = try decoded(Jobs.decode(job, FanOut.codec))
  posts = try Database.with_connection(delivery.pool) do |db| posts_of(db, given) end
  return ok() if posts.empty?

  _ = try Jobs.enqueue_all(delivery.posts, posts)
  ok()
end

def posts_of(db: Db.Connection, given: FanOut) -> Result[List[Jobs.NewJob]]
  stored = try Rooms.find_message(db, given.room_id, given.message_id)
  return gone("message_gone", "the message #{given.message_id} is gone") if stored.none?

  message = Rooms.clean(stored.unwrap!)
  room = try Rooms.find(db, message.creator_id, given.room_id)
  return gone("author_gone", "the author of the message #{given.message_id} left the room") if room.none?

  direct = room.unwrap!.room_type == Rooms.DIRECT
  hooks = try Bots.webhooks_for(db, given.room_id, direct, message.creator_id, Mentions.ids(message.body))
  ok(hooks.take(MAX_HOOKS).map do |hook| post_job(given, hook.bot_id) end)
end

def post_job(given: FanOut, bot_id: Int) -> Jobs.NewJob
  payload = PostJob(room_id: given.room_id, message_id: given.message_id, bot_id: bot_id)
  Jobs.json(POST, payload).with(
    max_attempts: ATTEMPTS,
    unique_key: some("#{given.message_id}:#{bot_id}"),
    group: some(bot_id.to_s),
    meta: {"message_id": given.message_id.to_s, "bot_id": bot_id.to_s},
  )
end

def post(delivery: Delivery, job: Jobs.Job) -> Result[Void]
  given = try decoded(Jobs.decode(job, PostJob.codec))
  found = try Database.with_connection(delivery.pool) do |db| post_of(db, given) end
  deliver(delivery, found)
end

def post_of(db: Db.Connection, given: PostJob) -> Result[Post]
  hook = try Bots.hook(db, given.bot_id)
  return gone("bot_gone", "the bot #{given.bot_id} has no webhook") if hook.none?

  stored = try Rooms.find_message(db, given.room_id, given.message_id)
  return gone("message_gone", "the message #{given.message_id} is gone") if stored.none?

  room = try Rooms.find(db, given.bot_id, given.room_id)
  return gone("bot_left_room", "the bot #{given.bot_id} left the room") if room.none?

  message = Rooms.clean(stored.unwrap!)
  text = HtmlSanitizer.plain_text_of_clean(message.body)
  ok(Post(room: room.unwrap!, message: message, text: text, hook: hook.unwrap!))
end

# One attempt. Only a connection that failed before anything was sent is tried again (refused, or a host that does
# not resolve); after that the webhook may have the post, so any failure drops the job.
def deliver(delivery: Delivery, post: Post) -> Result[Void]
  hook = post.hook
  if not delivery.private_addresses
    try public_host(hook.url, delivery.timeout_ms)
  end

  body = JSON.encode(payload(post)).bytes
  headers = [HTTP.Header(name: "Content-Type", value: "application/json")]
  options = HTTP.ClientOptions(timeout_ms: delivery.timeout_ms, max_body_bytes: MAX_ANSWER_BYTES)
  answer = HTTP.post_response(hook.url, body, headers, options)
  if not answer.ok?
    return error(answer.message, kind: "webhook.refused") if answer.message.start_with?(NOT_CONNECTED)
    return error(answer.message, kind: "webhook.dns") if answer.message.start_with?(NOT_FOUND)
    return gone("http_failed", answer.message) if not timed_out?(answer.message)

    return replied(reply(delivery, post, "Failed to respond within #{seconds(delivery.timeout_ms)}"))
  end

  text = reply_text(answer.unwrap!)
  return ok() if text.none?

  replied(reply(delivery, post, text.unwrap!))
end

# A reply that fails is not tried again, since the post would go to the webhook again.
def replied(result: Result[Void]) -> Result[Void]
  case result
    ok(_) -> ok()
    error(e) if e.is_a?("jobs.discard") -> error(e)
    error(e) -> gone("reply_failed", e.message)
  end
end

# A payload that cannot be read never will be.
def decoded[T](result: Result[T]) -> Result[T]
  return result if result.ok?

  gone("bad_payload", "the payload is not one of a webhook job: #{result.message}")
end

# The error that makes a job dead (`Jobs.discard`), with its cause in its kind for the log.
def gone[T](cause: String, message: String) -> Result[T] = error(message, kind: "jobs.discard.#{cause}")

# The wall clock when the app started, moved by a clock that never goes back, so a jump of the system time does not
# end the leases early.
def steady_clock() -> Fn[Int]
  offset = Time.now_ms() - Time.monotonic_ms()
  -> { offset + Time.monotonic_ms() }
end

def timed_out?(message: String) -> Bool = message.start_with?(TIMED_OUT)

# Rails writes `7.seconds` as "7 seconds".
def seconds(ms: Int) -> String
  count = ms / 1000
  return "1 second" if count == 1

  "#{count} seconds"
end

# The text of a `200` of `text/html` or `text/plain`; Rails' replies with an attachment wait for the uploads (#60).
def reply_text(answer: HTTP.Response) -> Optional[String]
  return none if answer.status != 200

  kind = HTTP.header_values(answer.headers, "content-type")
  return none if kind.empty? or not TEXT_TYPES.include?(kind[0].split(";")[0].strip.downcase)

  text = HTTP.text(answer.body, answer.headers)
  return none if not text.ok? or text.unwrap!.strip.empty?

  some(text.unwrap!.strip)
end

# The reply is the HTML of a message of the bot, as Rails creates it; `Rooms.post` cleans it.
def reply(delivery: Delivery, post: Post, text: String) -> Result[Void]
  hook = post.hook
  problem = Rooms.body_problem(text, delivery.max_message_length)
  return gone("reply_refused", "the reply of the bot #{hook.bot_id} was refused: #{problem}") if problem != ""

  stored = try Database.with_connection(delivery.pool) do |db|
    Rooms.post(db, post.room.id, hook.bot_id, OpenSSL.Random.hex(CLIENT_ID_BYTES), text)
  end

  case stored
    none -> return ok()
    some(message) -> CableWeb.message_created(delivery.cable, post.room, message)
  end

  ok()
end

def payload(post: Post) -> Payload
  hook = post.hook
  name: Optional[String] = some(post.room.name)
  if post.room.room_type == Rooms.DIRECT
    name = none
  end

  Payload(
    user: Author(id: post.message.creator_id, name: post.message.author),
    room: RoomRef(id: post.room.id, name: name, path: Routes.bot_messages_path(post.room.id, hook.key)),
    message: MessageRef(
      id: post.message.id,
      body: Body(html: post.message.body, plain: Bots.without_mentions(post.text, hook.name)),
      path: Routes.room_at_path(post.room.id, post.message.id),
    ),
  )
end

# An error unless every address of the host of `url` is on the open internet: one that drops the job for an address
# that is not, and one that runs it again when the host does not resolve, since nothing was sent.
def public_host(url: String, timeout_ms: Int) -> Result[Void]
  host = host_of(url)
  found = DNS.lookup(host, timeout_ms)
  return error(found.message, kind: "webhook.dns") if not found.ok?

  for address in found.unwrap!
    if not Bans.public_address?(address)
      return gone(
        "private_address",
        "#{host} is #{address}, which is not on the open internet (CAMPFIRE_WEBHOOK_PRIVATE_ADDRESSES)",
      )
    end
  end

  ok()
end

# The host of an `http://` or `https://` URL that `Bots.webhook_problem` let in, without the brackets of an IPv6 one.
def host_of(url: String) -> String
  start = url.index_of("//").unwrap_or(-2) + 2
  authority = url.slice(start, url.length - start).split("/")[0].split("?")[0].split("#")[0]
  if authority.start_with?("[")
    close = authority.index_of("]").unwrap_or(authority.length)
    return authority.slice(1, close - 1)
  end

  authority.split(":")[0]
end

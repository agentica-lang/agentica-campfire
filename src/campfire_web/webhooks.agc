## The webhooks of the chat bots (Rails' `Webhook`, `Bot::WebhookJob` and `MessagesController#deliver_webhooks_to_bots`).
## After a person posts a message, a task finds the bots it is meant for (`Bots.webhooks_for`: every bot of a direct
## room, the mentioned bots of another room, never the author; at most `MAX_HOOKS`) and posts the JSON of Rails to each
## webhook URL, each in a task of its own. A message that a bot posts through the API goes to no webhook, so two bots
## cannot answer each other forever. An answer `200` with `text/html` or `text/plain` is posted back to the room as a
## message of the bot, and an answer that takes longer than `CAMPFIRE_WEBHOOK_TIMEOUT` is answered with Rails' "Failed
## to respond within N seconds". A reply never goes to the webhooks again. A connection that fails before anything is
## sent is tried again, twice; anything else is logged and dropped. At most `MAX_RUNNING` posts run at once, and at most
## `MAX_PER_BOT` for one bot, so a slow bot cannot take every slot; the next ones wait in a queue of `MAX_WAITING`, and
## a post past that is logged and dropped.
##
## A webhook reaches only an address of the open internet (`Bans.public_address?`): every address that its host
## resolves to must be one, unless `CAMPFIRE_WEBHOOK_PRIVATE_ADDRESSES` is true. Rails does not check this (an
## administrator sets the URL); here a bot form cannot reach the services next to the app by default. The check comes
## before the post, which resolves the host again, so a name whose DNS changes in between is not caught
## (agentica-lang/agentica#1556).

import HTTP from "std/http"
import Bans from "../campfire/bans"
import Bots from "../campfire/bots"
import CableWeb from "cable"
import Database from "../campfire/repo/database"
import HtmlSanitizer from "../campfire/html_sanitizer"
import Mentions from "../campfire/mentions"
import Rooms from "../campfire/rooms"
import Routes from "routes"
import Slots from "../campfire/slots"
import {Config} from "../campfire/config"

## What the deliveries need, shared by the request tasks.
struct Hooks
  pool: Database.Pool
  cable: CableWeb.Cable
  timeout_ms: Int
  private_addresses: Bool
  max_message_length: Int
  running: ATS[String, Int]
  per_bot: ATS[String, Int]
  waiting: Channel[Post]
end

## One message for one bot.
struct Post
  room: Rooms.Room
  message: Rooms.Message
  text: String
  hook: Bots.Hook
end

## The deliveries of the app.
def new(config: Config, pool: Database.Pool, cable: CableWeb.Cable) -> Hooks
  waiting: Channel[Post] = Channel.new(MAX_WAITING)
  per_bot: ATS[String, Int] = ATS.new()
  Hooks(
    pool: pool,
    cable: cable,
    timeout_ms: config.webhook_timeout_ms,
    private_addresses: config.webhook_private_addresses,
    max_message_length: config.max_message_length,
    running: Slots.new(),
    per_bot: per_bot,
    waiting: waiting,
  )
end

## Starts the delivery of a new message of a person to the bots it is meant for and does not wait. The caller has given
## its database connection back. A message with no mention in a room that is not direct is meant for nobody and starts
## nothing.
def deliver_later(hooks: Hooks, room: Rooms.Room, message: Rooms.Message) -> Void
  mentioned = Mentions.ids(message.body)
  return if room.room_type != Rooms.DIRECT and mentioned.empty?

  text = HtmlSanitizer.plain_text_of_clean(message.body)
  _ = Task.spawn(&fan_out, Job(hooks: hooks, room: room, message: message, text: text, mentioned: mentioned))
end

private

MAX_RUNNING = 32
MAX_WAITING = 256
MAX_HOOKS = 16
MAX_PER_BOT = 4
# A connection that fails is tried this many times in all, with this pause times the number of the try in between.
ATTEMPTS = 3
PAUSE_MS = 500
# The most of an answer that is read.
MAX_ANSWER_BYTES = 1_048_576
TIMED_OUT = "network: operation timed out"
NOT_CONNECTED = "network: connection failed"
TEXT_TYPES = ["text/html", "text/plain"]
# Each reply is a new message, with a client id of its own.
CLIENT_ID_BYTES = 16

struct Job
  hooks: Hooks
  room: Rooms.Room
  message: Rooms.Message
  text: String
  mentioned: List[Int]
end

struct Work
  hooks: Hooks
  post: Post
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

def fan_out(job: Job) -> Void
  direct = job.room.room_type == Rooms.DIRECT
  found = Database.with_connection(job.hooks.pool) do |db|
    Bots.webhooks_for(db, job.room.id, direct, job.message.creator_id, job.mentioned)
  end

  if not found.ok?
    IO.warn("campfire: webhooks: the message #{job.message.id} was not delivered: #{found.message}")
    return
  end

  for hook in found.unwrap!.take(MAX_HOOKS)
    submit(job.hooks, Post(room: job.room, message: job.message, text: job.text, hook: hook))
  end
end

# The post waits in the queue, and a worker starts when a slot is free; else a worker that is running takes it, since
# a worker looks at the queue again after it gives its slot back.
def submit(hooks: Hooks, post: Post) -> Void
  if not Channel.send(hooks.waiting, post, 0).ok?
    IO.warn(
      "campfire: webhooks: the bot #{post.hook.bot_id} did not get the message #{post.message.id}, " +
      "since #{MAX_WAITING} posts are waiting",
    )

    return
  end

  if Slots.take?(hooks.running, MAX_RUNNING)
    _ = Task.spawn(&work, hooks)
  end
end

# Holds one slot and delivers waiting posts until none can run. Each post runs in a task of its own, so a crash of
# it is
# an `error` here and the slots are always given back.
def work(hooks: Hooks) -> Void
  post = next_post(hooks)
  while post.some?
    chosen = post.unwrap!
    done = Task.await(Task.spawn(&deliver, Work(hooks: hooks, post: chosen)))
    ATS.add(hooks.per_bot, chosen.hook.bot_id.to_s, -1)
    if not done.ok?
      IO.warn(
        "campfire: webhooks: the bot #{chosen.hook.bot_id} did not get the message #{chosen.message.id}: " +
        done.message,
      )
    end

    post = next_post(hooks)
  end
end

# A waiting post that may run, with a place of its bot taken and the slot kept, or `none` with the slot given back.
def next_post(hooks: Hooks) -> Optional[Post]
  found = pick(hooks)
  return found if found.some?

  Slots.release(hooks.running)
  late = pick(hooks)
  return none if late.none?

  return late if Slots.take?(hooks.running, MAX_RUNNING)

  # Every slot is taken again, by workers that look at the queue before they stop.
  post = late.unwrap!
  ATS.add(hooks.per_bot, post.hook.bot_id.to_s, -1)
  requeue(hooks, post)
  none
end

# The first waiting post whose bot has fewer than `MAX_PER_BOT` posts running; the others go back to the queue.
def pick(hooks: Hooks) -> Optional[Post]
  for _ in 0...MAX_WAITING
    queued = Channel.recv(hooks.waiting, 0)
    return none if not queued.ok?

    post = queued.unwrap!
    return some(post) if ATS.add(hooks.per_bot, post.hook.bot_id.to_s, 1) <= MAX_PER_BOT

    ATS.add(hooks.per_bot, post.hook.bot_id.to_s, -1)
    requeue(hooks, post)
  end

  none
end

def requeue(hooks: Hooks, post: Post) -> Void
  if not Channel.send(hooks.waiting, post, 0).ok?
    IO.warn("campfire: webhooks: the bot #{post.hook.bot_id} did not get the message #{post.message.id}")
  end
end

def deliver(given: Work) -> Result[Void]
  hooks = given.hooks
  post = given.post
  hook = post.hook
  if not hooks.private_addresses
    try public_host(hook.url, hooks.timeout_ms)
  end

  body = JSON.encode(payload(post)).bytes
  headers = [HTTP.Header(name: "Content-Type", value: "application/json")]
  options = HTTP.ClientOptions(timeout_ms: hooks.timeout_ms, max_body_bytes: MAX_ANSWER_BYTES)
  answer = HTTP.post_response(hook.url, body, headers, options)
  tries = 1
  while not answer.ok? and answer.message.start_with?(NOT_CONNECTED) and tries < ATTEMPTS
    Task.sleep(PAUSE_MS * tries)
    tries += 1
    answer = HTTP.post_response(hook.url, body, headers, options)
  end

  if not answer.ok?
    return reply(hooks, post, "Failed to respond within #{seconds(hooks.timeout_ms)}") if timed_out?(answer.message)

    return error(answer.message)
  end

  text = reply_text(answer.unwrap!)
  return ok() if text.none?

  reply(hooks, post, text.unwrap!)
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
def reply(hooks: Hooks, post: Post, text: String) -> Result[Void]
  hook = post.hook
  problem = Rooms.body_problem(text, hooks.max_message_length)
  return error("the reply of the bot #{hook.bot_id} was refused: #{problem}") if problem != ""

  stored = try Database.with_connection(hooks.pool) do |db|
    Rooms.post(db, post.room.id, hook.bot_id, OpenSSL.Random.hex(CLIENT_ID_BYTES), text)
  end

  case stored
    none -> return ok()
    some(message) -> CableWeb.message_created(hooks.cable, post.room, message)
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

# An error unless every address of the host of `url` is on the open internet.
def public_host(url: String, timeout_ms: Int) -> Result[Void]
  host = host_of(url)
  addresses = try DNS.lookup(host, timeout_ms)
  for address in addresses
    if not Bans.public_address?(address)
      return error("#{host} is #{address}, which is not on the open internet (CAMPFIRE_WEBHOOK_PRIVATE_ADDRESSES)")
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

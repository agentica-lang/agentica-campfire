## The webhooks of the chat bots (Rails' `Webhook`, `Bot::WebhookJob` and `MessagesController#deliver_webhooks_to_bots`).
## After a message is posted, a task finds the bots it is meant for (`Bots.webhooks_for`: every bot of a direct room,
## the mentioned bots of another room, never the author) and posts the JSON of Rails to each webhook URL, one after the
## other. An answer `200` with `text/html` or `text/plain` is posted back to the room as a message of the bot, and an
## answer that takes longer than `CAMPFIRE_WEBHOOK_TIMEOUT` is answered with Rails' "Failed to respond within N
## seconds". A reply never goes to the webhooks again. A connection that fails before anything is sent is tried again,
## twice; anything else is logged and dropped, and so is a message when `MAX_RUNNING` deliveries are under way.
##
## A webhook reaches only an address of the open internet (`Bans.public_address?`): every address that its host
## resolves to must be one, unless `CAMPFIRE_WEBHOOK_PRIVATE_ADDRESSES` is true. Rails does not check this (an
## administrator sets the URL); here a bot form cannot reach the services next to the app by default. The check comes
## before the post, which resolves the host again, so a name whose DNS changes in between is not caught.

import HTTP from "std/http"
import Bans from "../campfire/bans"
import Bots from "../campfire/bots"
import CableWeb from "cable"
import Database from "../campfire/repo/database"
import HtmlSanitizer from "../campfire/html_sanitizer"
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
end

## The deliveries of the app.
def new(config: Config, pool: Database.Pool, cable: CableWeb.Cable) -> Hooks
  Hooks(
    pool: pool,
    cable: cable,
    timeout_ms: config.webhook_timeout_ms,
    private_addresses: config.webhook_private_addresses,
    max_message_length: config.max_message_length,
    running: Slots.new(),
  )
end

## Starts the delivery of a new message to the bots it is meant for and does not wait. The caller has given its database
## connection back. A message with no `@` in a room that is not direct is meant for nobody and starts nothing.
def deliver_later(hooks: Hooks, room: Rooms.Room, message: Rooms.Message) -> Void
  text = HtmlSanitizer.plain_text_of_clean(message.body)
  return if room.room_type != Rooms.DIRECT and not text.include?("@")

  if not Slots.take?(hooks.running, MAX_RUNNING)
    IO.warn("campfire: webhooks: the message #{message.id} was not delivered, since #{MAX_RUNNING} are under way")
    return
  end

  _ = Task.spawn(&run, Job(hooks: hooks, room: room, message: message, text: text))
end

private

# The deliveries under way at once; each can wait for a slow webhook.
MAX_RUNNING = 32
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

def run(job: Job) -> Void
  delivered = deliver_all(job)
  if not delivered.ok?
    IO.warn("campfire: webhooks: the message #{job.message.id} was not delivered: #{delivered.message}")
  end

  Slots.release(job.hooks.running)
end

def deliver_all(job: Job) -> Result[Void]
  direct = job.room.room_type == Rooms.DIRECT
  hooks = try Database.with_connection(job.hooks.pool) do |db|
    Bots.webhooks_for(db, job.room.id, direct, job.message.creator_id, job.text)
  end

  for hook in hooks
    done = deliver(job, hook)
    if not done.ok?
      IO.warn("campfire: webhooks: the bot #{hook.bot_id} did not get the message #{job.message.id}: #{done.message}")
    end
  end

  ok()
end

def deliver(job: Job, hook: Bots.Hook) -> Result[Void]
  if not job.hooks.private_addresses
    try public_host(hook.url, job.hooks.timeout_ms)
  end

  body = JSON.encode(payload(job, hook)).bytes
  headers = [HTTP.Header(name: "Content-Type", value: "application/json")]
  options = HTTP.ClientOptions(timeout_ms: job.hooks.timeout_ms, max_body_bytes: MAX_ANSWER_BYTES)
  answer = HTTP.post_response(hook.url, body, headers, options)
  tries = 1
  while not answer.ok? and answer.message.start_with?(NOT_CONNECTED) and tries < ATTEMPTS
    Task.sleep(PAUSE_MS * tries)
    tries += 1
    answer = HTTP.post_response(hook.url, body, headers, options)
  end

  if not answer.ok?
    return reply(job, hook, "Failed to respond within #{seconds(job.hooks.timeout_ms)}") if timed_out?(answer.message)

    return error(answer.message)
  end

  text = reply_text(answer.unwrap!)
  return ok() if text.none?

  reply(job, hook, text.unwrap!)
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
def reply(job: Job, hook: Bots.Hook, text: String) -> Result[Void]
  problem = Rooms.body_problem(text, job.hooks.max_message_length)
  return error("the reply of the bot #{hook.bot_id} was refused: #{problem}") if problem != ""

  stored = try Database.with_connection(job.hooks.pool) do |db|
    Rooms.post(db, job.room.id, hook.bot_id, OpenSSL.Random.hex(CLIENT_ID_BYTES), text)
  end

  case stored
    none -> return ok()
    some(message) -> CableWeb.message_created(job.hooks.cable, job.room, message)
  end

  ok()
end

def payload(job: Job, hook: Bots.Hook) -> Payload
  name: Optional[String] = some(job.room.name)
  if job.room.room_type == Rooms.DIRECT
    name = none
  end

  Payload(
    user: Author(id: job.message.creator_id, name: job.message.author),
    room: RoomRef(id: job.room.id, name: name, path: Routes.bot_messages_path(job.room.id, hook.key)),
    message: MessageRef(
      id: job.message.id,
      body: Body(html: job.message.body, plain: Bots.without_mentions(job.text, hook.name)),
      path: Routes.room_at_path(job.room.id, job.message.id),
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

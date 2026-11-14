## The chat bots of the account over the `users` table (`User::Bot` of Rails): a bot is a user with the role `bot`, a
## name and a `bot_token`, and no email or password, so it cannot sign in. Its key is `ID-TOKEN`, with a token of 12
## letters and digits; the key is what a bot shows to the messages API (`authenticate`). Every change runs in one
## write transaction that checks again that the actor is an active administrator, and finds only an active bot, as
## `User.active_bots.find` does: a deactivated bot, a person and a missing user are the same `Missing`. A bot may have a
## webhook URL (`webhooks`, one row as Rails' `has_one`), where the messages that are meant for it are posted
## (`webhooks_for`).

import Db from "pkg/db/db"
import Accounts from "accounts"
import Rails from "repo/rails"
import Rooms from "rooms"
import {int_of, text_of} from "repo/rows"

## The longest name of a bot, in characters.
MAX_NAME_LENGTH = 100
## The longest webhook URL, in characters.
MAX_WEBHOOK_URL_LENGTH = 2_000

## A bot as the page lists it. `key` is the secret that names it: `ID-TOKEN`.
struct Bot
  id: Int
  name: String
  key: String
  webhook_url: String = ""
end

## A bot whose webhook a message goes to.
struct Hook
  bot_id: Int
  name: String
  key: String
  url: String
end

## What is wrong with a bot name, or "". The caller strips it first. Rails only asks the form for the field; a blank
## name would leave the bot with nothing to show, so it is refused here.
def name_problem(name: String) -> String
  return "Give the bot a name of 1 to #{MAX_NAME_LENGTH} characters" if name.empty? or name.length > MAX_NAME_LENGTH

  ""
end

## What is wrong with a webhook URL, or "" (an empty one, which means none, is fine). The caller strips it first. It is
## an `http://` or `https://` URL with a host and no user or password in it, and no space; whether its host may be
## reached is checked when a message is delivered.
def webhook_problem(url: String) -> String
  return "" if url.empty?

  problem = (
    "Give the webhook a URL that starts with http:// or https://, of at most #{MAX_WEBHOOK_URL_LENGTH} characters"
  )

  return problem if url.length > MAX_WEBHOOK_URL_LENGTH or url.include?(" ")

  rest = ""
  if url.start_with?("http://")
    rest = url.slice(7, url.length - 7)
  elsif url.start_with?("https://")
    rest = url.slice(8, url.length - 8)
  end

  authority = rest.split("/")[0].split("?")[0].split("#")[0]
  return problem if authority.empty? or authority.include?("@") or authority.start_with?(":")

  ""
end

## The bots that a new message of `creator_id` in the room goes to, as `MessagesController#deliver_webhooks_to_bots`
## picks them: the active bots of the room with a webhook, but the author, and in a room that is not `direct` only the
## ones that `text` (the plain text of the message) mentions. Until mentions exist (#57) a mention is the text `@NAME`
## not followed by a letter, a digit or `_`, which is also the plain text of a Rails mention.
def webhooks_for(conn: Db.Connection, room_id: Int, direct: Bool, creator_id: Int, text: String) -> Result[List[Hook]]
  return ok([]) if not direct and not text.include?("@")

  rows = try Db.query(
    conn,
    "select users.id, users.name, users.bot_token, webhooks.url from memberships " +
    "join users on users.id = memberships.user_id join webhooks on webhooks.user_id = users.id " +
    "where memberships.room_id = ? and users.id <> ? and users.role = #{Rails.BOT} and " +
    "users.status = #{Rails.ACTIVE} and webhooks.url is not null and webhooks.url <> '' order by users.id",
    [Db.Value.Int(room_id), Db.Value.Int(creator_id)],
  )

  hooks = rows.map do |row|
    id = int_of(row, "id")
    Hook(bot_id: id, name: text_of(row, "name"), key: "#{id}-#{text_of(row, "bot_token")}", url: text_of(row, "url"))
  end

  return ok(hooks) if direct

  ok(hooks.select do |hook| mentioned?(text, hook.name) end)
end

## `text` without the mentions of `name` and the space around it, as the `plain` body of Rails' payload.
def without_mentions(text: String, name: String) -> String = text.replace("@#{name}", "").strip

## The active bots by name, as `User.active_bots.ordered` lists them.
def active(conn: Db.Connection) -> Result[List[Bot]]
  rows = try Db.query(conn, "#{SELECT} order by lower(name), id", [])
  ok(rows.map do |row| bot_of(row) end)
end

## The active bot with this id, or `none`.
def find(conn: Db.Connection, bot_id: Int) -> Result[Optional[Bot]]
  rows = try Db.query(conn, "#{SELECT} and id = ?", [Db.Value.Int(bot_id)])
  return ok(none) if rows.empty?

  ok(some(bot_of(rows[0])))
end

## The active bot that `key` (`ID-TOKEN`) names, or `none` for any other text, a bot with another token (a key that a
## new token ended), a deactivated bot and a user who is not a bot. The bot is found by its id with the rule of `find`
## (`role = bot and status = active`), and the key is then compared with the stored one in constant time, since the
## token is stored as plain text and a `=` in SQL would stop at the first byte that differs. An empty token never
## matches, so a user with no token is not reached by a key that ends at the dash.
def authenticate(conn: Db.Connection, key: String) -> Result[Optional[Bot]]
  given = key.strip
  dash = given.index_of("-")
  return ok(none) if dash.none?

  id = given.slice(0, dash.unwrap!).to_i
  token = given.slice(dash.unwrap! + 1, given.length - dash.unwrap! - 1)
  return ok(none) if not id.ok? or token.empty?

  found = try find(conn, id.unwrap!)
  case found
    some(bot) if OpenSSL.HMAC.secure_compare(bot.key.bytes, given.bytes) -> ok(some(bot))
    _ -> ok(none)
  end
end

## Makes a bot named `name` with the webhook `webhook_url` ("" for none) for `actor_id` and puts it in every open room,
## as a new person is. It gives false, with nothing made, when the actor is not an active administrator.
def create(conn: Db.Connection, actor_id: Int, name: String, webhook_url: String = "") -> Result[Bool]
  Db.transaction(conn) do |tx| create_in(tx, actor_id, name, webhook_url) end
end

## Renames the bot and sets its webhook URL, "" taking it away (`update_bot!`). `Refused` is an actor who is not an
## active administrator; `Missing` is no active bot with this id.
def update(
  conn: Db.Connection,
  actor_id: Int,
  bot_id: Int,
  name: String,
  webhook_url: String,
) -> Result[Accounts.Change]
  Db.transaction(conn) do |tx| update_in(tx, actor_id, bot_id, name, webhook_url) end
end

## Gives the bot a new token, so the old key stops working (`reset_bot_key`). Results as `rename`.
def reset_key(conn: Db.Connection, actor_id: Int, bot_id: Int) -> Result[Accounts.Change]
  Db.transaction(conn) do |tx| change_in(tx, actor_id, bot_id, "bot_token = ?", [Db.Value.Text(new_token())]) end
end

## Deactivates the bot as `User#deactivate` does: it leaves the open and closed rooms (the direct messages stay) and is
## no longer an active bot, so its key finds nobody. Its messages stay. A bot has no sessions, searches or address to
## clean up. Results as `rename`.
def deactivate(conn: Db.Connection, actor_id: Int, bot_id: Int) -> Result[Accounts.Change]
  Db.transaction(conn) do |tx| deactivate_in(tx, actor_id, bot_id) end
end

private

# The characters of a token (`OpenSSL.Random.alphanumeric`).
ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
TOKEN_LENGTH = 12
# 256 is not a multiple of 62, so the bytes from 248 on are skipped: each character is then as likely as any other.
FAIR_BELOW = 248
NOW = Rails.NOW
# The active bots; a caller adds `and id = ?` or an order.
SELECT = (
  "select id, name, bot_token, (select url from webhooks where webhooks.user_id = users.id order by id limit 1) " +
  "as webhook_url from users where role = #{Rails.BOT} and status = #{Rails.ACTIVE}"
)
# What may follow a mention: anything but a letter, a digit or `_`.
WORD = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

def bot_of(row: Db.Row) -> Bot
  id = int_of(row, "id")
  Bot(
    id: id,
    name: text_of(row, "name"),
    key: "#{id}-#{text_of(row, "bot_token")}",
    webhook_url: text_of(row, "webhook_url"),
  )
end

def create_in(tx: Db.Connection, actor_id: Int, name: String, webhook_url: String) -> Result[Bool]
  allowed = try Accounts.administrator?(tx, actor_id)
  return ok(false) if not allowed

  rows = try Db.query(
    tx,
    "insert into users (name, bot_token, role, status, created_at, updated_at) " +
    "values (?, ?, #{Rails.BOT}, #{Rails.ACTIVE}, #{NOW}, #{NOW}) returning id",
    [Db.Value.Text(name), Db.Value.Text(new_token())],
  )

  bot_id = int_of(rows[0], "id")
  try Rooms.grant_open_rooms(tx, bot_id)
  try set_webhook(tx, bot_id, webhook_url)
  ok(true)
end

def update_in(
  tx: Db.Connection,
  actor_id: Int,
  bot_id: Int,
  name: String,
  webhook_url: String,
) -> Result[Accounts.Change]
  change = try change_in(tx, actor_id, bot_id, "name = ?", [Db.Value.Text(name)])
  if change == Accounts.Change.Changed
    try set_webhook(tx, bot_id, webhook_url)
  end

  ok(change)
end

def set_webhook(tx: Db.Connection, bot_id: Int, url: String) -> Result[Void]
  id = Db.Value.Int(bot_id)
  if url.empty?
    try Db.execute(tx, "delete from webhooks where user_id = ?", [id])
    return ok()
  end

  changed = try Db.execute(
    tx,
    "update webhooks set url = ?, updated_at = #{NOW} where user_id = ?",
    [Db.Value.Text(url), id],
  )

  if changed == 0
    try Db.execute(
      tx,
      "insert into webhooks (url, user_id, created_at, updated_at) values (?, ?, #{NOW}, #{NOW})",
      [Db.Value.Text(url), id],
    )
  end

  ok()
end

def mentioned?(text: String, name: String) -> Bool
  pieces = text.split("@#{name}")
  return false if pieces.size < 2

  pieces.drop(1).any? do |after| after.empty? or not WORD.include?(after.slice(0, 1)) end
end

# `set` is the assignment of one column (its `?` among `args`); the bot must be active, which a deactivated one and a
# person are not.
def change_in(
  tx: Db.Connection,
  actor_id: Int,
  bot_id: Int,
  set: String,
  args: List[Db.Value],
) -> Result[Accounts.Change]
  allowed = try Accounts.administrator?(tx, actor_id)
  return ok(Accounts.Change.Refused) if not allowed

  changed = try Db.execute(
    tx,
    "update users set #{set}, updated_at = #{NOW} where id = ? and role = #{Rails.BOT} and status = #{Rails.ACTIVE}",
    args.concat([Db.Value.Int(bot_id)]),
  )

  return ok(Accounts.Change.Missing) if changed == 0

  ok(Accounts.Change.Changed)
end

def deactivate_in(tx: Db.Connection, actor_id: Int, bot_id: Int) -> Result[Accounts.Change]
  change = try change_in(tx, actor_id, bot_id, "status = #{Rails.DEACTIVATED}", [])
  if change == Accounts.Change.Changed
    try Rooms.leave_shared_rooms(tx, bot_id)
  end

  ok(change)
end

# Twelve letters and digits drawn from the system's random source.
def new_token() -> String
  token = ""
  while token.length < TOKEN_LENGTH
    for byte in OpenSSL.Random.random_bytes(TOKEN_LENGTH)
      if byte < FAIR_BELOW and token.length < TOKEN_LENGTH
        token = "#{token}#{ALPHABET.slice(byte % ALPHABET.length, 1)}"
      end
    end
  end

  token
end

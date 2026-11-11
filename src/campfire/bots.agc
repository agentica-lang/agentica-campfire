## The chat bots of the account over the `users` table (`User::Bot` of Rails): a bot is a user with the role `bot`, a
## name and a `bot_token`, and no email or password, so it cannot sign in. Its key is `ID-TOKEN`, with a token of 12
## letters and digits; the key is what a bot shows to the messages API (`authenticate`). Every change runs in one
## write transaction that checks again that the actor is an active administrator, and finds only an active bot, as
## `User.active_bots.find` does: a deactivated bot, a person and a missing user are the same `Missing`.

import Db from "pkg/db/db"
import Accounts from "accounts"
import Rails from "repo/rails"
import Rooms from "rooms"
import {int_of, text_of} from "repo/rows"

# The characters of a token (`OpenSSL.Random.alphanumeric`).
ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
TOKEN_LENGTH = 12

# 256 is not a multiple of 62, so the bytes from 248 on are skipped: each character is then as likely as any other.
FAIR_BELOW = 248

NOW = Rails.NOW

# The active bots; a caller adds `and id = ?` or an order.
SELECT = "select id, name, bot_token from users where role = #{Rails.BOT} and status = #{Rails.ACTIVE}"

## The longest name of a bot, in characters.
export MAX_NAME_LENGTH = 100

## A bot as the page lists it. `key` is the secret that names it: `ID-TOKEN`.
export struct Bot
  id: Int
  name: String
  key: String
end

## What is wrong with a bot name, or "". The caller strips it first. Rails only asks the form for the field; a blank
## name would leave the bot with nothing to show, so it is refused here.
export def name_problem(name: String) -> String
  return "Give the bot a name of 1 to #{MAX_NAME_LENGTH} characters" if name.empty? or name.length > MAX_NAME_LENGTH

  ""
end

## The active bots by name, as `User.active_bots.ordered` lists them.
export def active(conn: Db.Connection) -> Result[List[Bot]]
  rows = try Db.query(conn, "#{SELECT} order by lower(name), id", [])
  ok(rows.map do |row| bot_of(row) end)
end

## The active bot with this id, or `none`.
export def find(conn: Db.Connection, bot_id: Int) -> Result[Optional[Bot]]
  rows = try Db.query(conn, "#{SELECT} and id = ?", [Db.Value.Int(bot_id)])
  return ok(none) if rows.empty?

  ok(some(bot_of(rows[0])))
end

## The active bot that `key` (`ID-TOKEN`) names, or `none` for any other text, a bot with another token (a key that a
## new token ended), a deactivated bot and a user who is not a bot. The bot is found by its id with the rule of `find`
## (`role = bot and status = active`), and the key is then compared with the stored one in constant time, since the
## token is stored as plain text and a `=` in SQL would stop at the first byte that differs. An empty token never
## matches, so a user with no token is not reached by a key that ends at the dash.
export def authenticate(conn: Db.Connection, key: String) -> Result[Optional[Bot]]
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

## Makes a bot named `name` for `actor_id` and puts it in every open room, as a new person is. It gives false, with
## nothing made, when the actor is not an active administrator.
export def create(conn: Db.Connection, actor_id: Int, name: String) -> Result[Bool]
  Db.transaction(conn) do |tx| create_in(tx, actor_id, name) end
end

## Renames the bot. `Refused` is an actor who is not an active administrator; `Missing` is no active bot with this id.
export def rename(conn: Db.Connection, actor_id: Int, bot_id: Int, name: String) -> Result[Accounts.Change]
  Db.transaction(conn) do |tx| change_in(tx, actor_id, bot_id, "name = ?", [Db.Value.Text(name)]) end
end

## Gives the bot a new token, so the old key stops working (`reset_bot_key`). Results as `rename`.
export def reset_key(conn: Db.Connection, actor_id: Int, bot_id: Int) -> Result[Accounts.Change]
  Db.transaction(conn) do |tx| change_in(tx, actor_id, bot_id, "bot_token = ?", [Db.Value.Text(new_token())]) end
end

## Deactivates the bot as `User#deactivate` does: it leaves the open and closed rooms (the direct messages stay) and is
## no longer an active bot, so its key finds nobody. Its messages stay. A bot has no sessions, searches or address to
## clean up. Results as `rename`.
export def deactivate(conn: Db.Connection, actor_id: Int, bot_id: Int) -> Result[Accounts.Change]
  Db.transaction(conn) do |tx| deactivate_in(tx, actor_id, bot_id) end
end

def bot_of(row: Db.Row) -> Bot
  id = int_of(row, "id")
  Bot(id: id, name: text_of(row, "name"), key: "#{id}-#{text_of(row, "bot_token")}")
end

def create_in(tx: Db.Connection, actor_id: Int, name: String) -> Result[Bool]
  allowed = try Accounts.administrator?(tx, actor_id)
  return ok(false) if not allowed

  rows = try Db.query(
    tx,
    "insert into users (name, bot_token, role, status, created_at, updated_at) " +
    "values (?, ?, #{Rails.BOT}, #{Rails.ACTIVE}, #{NOW}, #{NOW}) returning id",
    [Db.Value.Text(name), Db.Value.Text(new_token())],
  )

  try Rooms.grant_open_rooms(tx, int_of(rows[0], "id"))
  ok(true)
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

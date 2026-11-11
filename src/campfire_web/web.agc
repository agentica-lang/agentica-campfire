## The routes of the app, on Bond.

import Bond from "pkg/bond/bond"
import Cache from "std/cache"
import AccountsWeb from "accounts"
import AuthWeb from "auth"
import AvatarsWeb from "avatars"
import BanFlag from "ban_flag"
import BoostsWeb from "boosts"
import BotMessagesWeb from "bot_messages"
import BotsWeb from "bots"
import CableWeb from "cable"
import Database from "../campfire/repo/database"
import Failure from "failure"
import Mailer from "../campfire/mail/mailer"
import PageCache from "page_cache"
import ProfilesWeb from "profiles"
import Routes from "routes"
import RoomsWeb from "rooms"
import SearchesWeb from "searches"
import SidebarsWeb from "sidebars"
import SignedId from "../campfire/signed_id"
import Slots from "../campfire/slots"
import {Config} from "../campfire/config"

UP_PAGE = "<!DOCTYPE html><html><body style=\"background-color: green\"></body></html>"

# The biggest file that the assets folder serves: 4 MiB, far above a stylesheet or a script of this app.
STYLESHEET_MAX_BYTES = 4 * 1024 * 1024

# The statuses of a redirect (not 304, which answers a conditional request and keeps the headers of the cached copy).
REDIRECTS = [301, 302, 303, 307, 308]
NOT_MODIFIED = 304
CACHE_CONTROL_NAME_LENGTH = 13
CONTENT_TYPE_NAME_LENGTH = 12

struct Health
  status: String
  schema_version: Int
end

## The app with its routes: the home page, which needs a sign-in, the health check, which says the schema version that
## the database was migrated to, the routes of `AuthWeb`, which send email through `mailer`, those of `RoomsWeb` and
## `AccountsWeb`, the boosts of the messages (`BoostsWeb`), the messages API of the chat bots (`BotMessagesWeb`), the
## user page and the profile, the sidebar, the search, the avatars (checked with the key of `SECRET_KEY_BASE`) and the
## folder of the stylesheet, and `/cable`, the live WebSocket (`CableWeb`), which the routes that change a room
## broadcast through `cable`. `config.assets_dir` must be a folder, which `App.start` checks. `messages` is the cache
## of rendered messages for the room pages (`MessageCache.start`); without it every message is rendered each time.
## `pages` keeps the room page, the older messages, the sidebar and the search whole (`PageCache.start`); without it
## each is made for every request.
export def build(
  config: Config,
  pool: Database.Pool,
  schema_version: Int,
  mailer: Mailer.Mailer,
  cable: CableWeb.Cable,
  messages: Optional[Cache.Store] = none,
  pages: Optional[PageCache.Pages] = none,
) -> Bond.App
  slots = Slots.new()
  bans = BanFlag.new()
  (
    Bond.app()
    |> AuthWeb.add(config, pool, mailer, cable.hub, slots, bans, pages)
    |> CableWeb.add(cable, config)
    |> RoomsWeb.add(pool, cable, messages, pages, config.secure_cookies, config.max_message_length)
    |> BoostsWeb.add(pool, cable)
    |> BotMessagesWeb.add(pool, cable, config)
    |> AccountsWeb.add(config, pool, cable, bans)
    |> BotsWeb.add(pool, config)
    |> SidebarsWeb.add(pool, cable, pages)
    |> SearchesWeb.add(pool, pages)
    |> AvatarsWeb.add(pool, pages, avatar_key(config), config.storage_dir)
    |> ProfilesWeb.add(config, pool, slots, avatar_key(config), cable.hub)
    |> Bond.static(Routes.ASSETS, config.assets_dir, STYLESHEET_MAX_BYTES, 0, true)
    |> Bond.get(Routes.HOME) do |conn| RoomsWeb.home(conn, pool) end
    |> Bond.get(Routes.HEALTH) do |conn| health(conn, schema_version) end
    |> Bond.get(Routes.UP) do |conn| up(conn) end
    |> Bond.after() do |conn| revalidate(conn) end
    |> Bond.not_found() do |conn| ok(Bond.text(conn, 404, Routes.MISSING)) end
    |> Bond.on_error() do |conn, message| ok(Failure.answer(conn, message)) end
  )
end

## An HTML page or a redirect that has no `Cache-Control` of its own gets the Rails default, so a browser never shows
## an old page (which links an old fingerprinted stylesheet) after a deploy. A handler's own header stays, in any
## casing: `no-store` of the pages with a token, the cache policy of the room pages, the year of /assets and the
## avatars. A 304 and every other status are left as they are. It runs on every answer, so it reads the header list
## once and compares the length of a name before it lowercases it (Bond writes `content-type: text/html;
## charset=utf-8` exactly, so the value is compared as written).
export def revalidate(conn: Bond.Conn) -> Result[Bond.Conn]
  page = false
  for header in conn.response_headers
    name = header.name
    return ok(conn) if name.length == CACHE_CONTROL_NAME_LENGTH and name.downcase == "cache-control"

    if name.length == CONTENT_TYPE_NAME_LENGTH and name.downcase == "content-type"
      page = header.value.start_with?("text/html")
    end
  end

  if (page and conn.status != NOT_MODIFIED) or REDIRECTS.include?(conn.status)
    return ok(Bond.header(conn, "cache-control", PageCache.CACHE_CONTROL))
  end

  ok(conn)
end

# For a load balancer or a container check: 200 while the process serves, and the schema that it started on.
def health(conn: Bond.Conn, schema_version: Int) -> Result[Bond.Conn]
  ok(Bond.json(conn, 200, JSON.from(Health(status: "ok", schema_version: schema_version))))
end

# What `/up` of Rails answers, so a check made for Rails (the benchmark harness looks for the colour) works here.
def up(conn: Bond.Conn) -> Result[Bond.Conn] = ok(Bond.html(conn, 200, UP_PAGE))

# The key that the avatar links are checked with, from `SECRET_KEY_BASE`; `none` without one, so no link is valid. A
# secret that is set always makes a key (PBKDF2 with fixed sizes cannot fail), so `none` only means "not set".
def avatar_key(config: Config) -> Optional[Bytes]
  return none if config.secret_key_base.empty?

  key = SignedId.key(config.secret_key_base)
  return none if not key.ok?

  some(key.unwrap!)
end

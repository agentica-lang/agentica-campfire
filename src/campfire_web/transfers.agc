## Signing in on another device, as Rails' `Sessions::TransfersController` and `QrCodeController`. A signed-in person
## posts to `/session/transfers` and gets a page with a link and its QR code (`Transfers`: one use, 15 minutes). The link
## (`GET /session/transfers/TOKEN`) is a page with one button, so a preview or a scanner that only opens it does not use
## it up; the button sends `PUT` (or a `POST` with `_method=put`), which signs that browser in and goes home, or answers
## 400 for a link that does not work. `GET /qr_code/ID` draws the text that ID holds (Base64url) as an SVG QR code, 400
## for an ID that is not Base64url or holds too much. The link page and the two `/session/transfers/TOKEN` answers need
## no sign-in; the page with the link is `no-store`.

import Bond from "pkg/bond/bond"
import Auth from "../campfire/auth"
import AuthWeb from "auth"
import Blocks from "blocks"
import BotMessagesWeb from "bot_messages"
import Database from "../campfire/repo/database"
import QrCode from "../campfire/qr_code"
import Routes from "routes"
import Transfers from "../campfire/transfers"
import Views from "views"
import {Config} from "../campfire/config"

## Adds the routes of the transfer links and of the QR codes to `app`.
def add(app: Bond.App, config: Config, pool: Database.Pool) -> Bond.App
  links = Transfers.new()
  on_post_transfers = Blocks.handler do |conn| create(conn, config, links) end
  on_get_transfer = Blocks.handler do |conn| ok(show(conn)) end
  on_post_transfer = Blocks.handler do |conn| post(conn, pool, links) end
  on_put_transfer = Blocks.handler do |conn| use(conn, pool, links) end
  on_get_qr_code = Blocks.handler do |conn| ok(qr_code(conn)) end

  (
    app
    |> Bond.post(Routes.SESSION_TRANSFERS, on_post_transfers)
    |> Bond.get(Routes.SESSION_TRANSFER, on_get_transfer)
    |> Bond.post(Routes.SESSION_TRANSFER, on_post_transfer)
    |> Bond.put(Routes.SESSION_TRANSFER, on_put_transfer)
    |> Bond.get(Routes.QR_CODE, on_get_qr_code)
  )
end

private

# `expires_in 1.year, public: true` of Rails' `QrCodeController`: the picture of a text never changes.
QR_CACHE_CONTROL = "max-age=31536000, public"
SVG_TYPE = "image/svg+xml; charset=utf-8"

def create(conn: Bond.Conn, config: Config, links: ATS[String, Int]) -> Result[Bond.Conn]
  user = try AuthWeb.assigned_user(conn)
  return ok(Bond.redirect(conn, Routes.SIGN_IN)) if user.none?

  token = Transfers.issue(links, user.unwrap!.id, Time.monotonic_ms())
  return ok(Bond.html(conn, 503, Views.busy("Too many sign-in links, try again later"))) if token.none?

  url = BotMessagesWeb.origin(conn, config) + Routes.session_transfer_path(token.unwrap!)
  code = QrCode.encode(url.bytes)
  svg = ""
  if code.ok?
    svg = Views.qr_code(code.unwrap!)
  end

  ok(AuthWeb.private_page(Bond.html(conn, 200, Views.transfer_link(url, svg))))
end

def show(conn: Bond.Conn) -> Bond.Conn
  path = Routes.session_transfer_path(Bond.param(conn, "id").unwrap_or(""))
  AuthWeb.private_page(Bond.html(conn, 200, Views.transfer_form(path)))
end

def post(conn: Bond.Conn, pool: Database.Pool, links: ATS[String, Int]) -> Result[Bond.Conn]
  method = try AuthWeb.form_method(conn)
  if method != Routes.METHOD_PUT
    return ok(Bond.header(Bond.text(conn, 405, "method not allowed"), "allow", Routes.SESSION_TRANSFER_ALLOW))
  end

  use(conn, pool, links)
end

# Rails' `head :bad_request` for a link that does not work, whatever the reason.
def use(conn: Bond.Conn, pool: Database.Pool, links: ATS[String, Int]) -> Result[Bond.Conn]
  token = Bond.param(conn, "id").unwrap_or("")
  user_id = Transfers.redeem(links, token, Time.monotonic_ms())
  return ok(bad_request(conn)) if user_id.none?

  agent = Bond.request_header(conn, "user-agent").unwrap_or("")
  opened = try Database.with_connection(pool) do |db|
    Auth.open_session(db, user_id.unwrap!, agent, conn.remote_addr)
  end

  return ok(bad_request(conn)) if opened.none?

  ok(AuthWeb.signed_in(conn, opened.unwrap!))
end

def bad_request(conn: Bond.Conn) -> Bond.Conn = Bond.text(conn, 400, "Bad Request")

def qr_code(conn: Bond.Conn) -> Bond.Conn
  text = Base64.urlsafe_decode64(Bond.param(conn, "id").unwrap_or(""))
  return bad_request(conn) if not text.ok?

  code = QrCode.encode(text.unwrap!)
  return bad_request(conn) if not code.ok?

  svg = Bond.header(Bond.html(conn, 200, Views.qr_code(code.unwrap!)), "content-type", SVG_TYPE)
  Bond.header(svg, "cache-control", QR_CACHE_CONTROL)
end

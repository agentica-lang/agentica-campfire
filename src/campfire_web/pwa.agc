## The installable web app, as Rails' `PwaController` and the show of `Accounts::LogosController`: the manifest
## (`/webmanifest.json`), the service worker (`/service-worker.js`) and the icon of the account (`/account/logo`, the
## large one, or `?size=small`). All three need no sign-in. The icon is the stock one of Rails until the account can
## have a logo of its own.

import Bond from "pkg/bond/bond"
import Blocks from "blocks"
import Accounts from "../campfire/accounts"
import Database from "../campfire/repo/database"
import Routes from "routes"

## Adds the three routes to `app`. `assets_dir` is the folder of the stock icons.
def add(app: Bond.App, pool: Database.Pool, assets_dir: String) -> Bond.App
  on_get_manifest = Blocks.handler do |conn| manifest(conn, pool) end
  on_get_worker = Blocks.handler do |conn| ok(service_worker(conn)) end
  on_get_logo = Blocks.handler do |conn| logo(conn, assets_dir) end
  (
    app
    |> Bond.get(Routes.WEBMANIFEST, on_get_manifest)
    |> Bond.get(Routes.SERVICE_WORKER, on_get_worker)
    |> Bond.get(Routes.ACCOUNT_LOGO, on_get_logo)
  )
end

## The script of the service worker. It keeps the stylesheet and the script of the pages (fingerprinted, so a kept copy
## is never stale) and answers them from its cache; every other request, a page, a form, the API, an icon or `/cable`,
## goes to the network as if there were no worker, and nothing else is ever kept. A new build is a new script (the names
## are in it), so the browser installs it and the old cache is deleted.
def service_worker_script() -> String
  <<~JS
    const CACHE = "campfire-shell-#{Routes.STYLESHEET}-#{Routes.SCRIPT}";
    const SHELL = ["#{Routes.STYLESHEET}", "#{Routes.SCRIPT}"];

    self.addEventListener("install", (event) => {
      event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
    });

    self.addEventListener("activate", (event) => {
      event.waitUntil(
        caches.keys().then((names) =>
          Promise.all(names.filter((name) => name.startsWith("campfire-shell-") && name !== CACHE).map((name) => caches.delete(name)))
        ).then(() => self.clients.claim())
      );
    });

    self.addEventListener("fetch", (event) => {
      const request = event.request;
      if (request.method !== "GET") return;
      const url = new URL(request.url);
      if (url.origin !== self.location.origin || url.search !== "" || !SHELL.includes(url.pathname)) return;
      event.respondWith(caches.match(request).then((kept) => kept || fetch(request)));
    });
  JS
end

private

# `expires_in 5.minutes, public: true, stale_while_revalidate: 1.week` of Rails' logos controller.
LOGO_CACHE_CONTROL = "max-age=300, public, stale-while-revalidate=604800"
LARGE_ICON = "app-icon.png"
SMALL_ICON = "app-icon-192.png"
DEFAULT_NAME = "Campfire"
DESCRIPTION = "A chat app from the makers of Basecamp and HEY."
THEME_COLOR = "#ffffff"

struct Icon
  src: String
  type: String
  sizes: String
  purpose: String
end

struct Manifest
  name: String
  icons: List[Icon]
  start_url: String
  display: String
  scope: String
  description: String
  categories: List[String]
  theme_color: String
  background_color: String
end

def manifest(conn: Bond.Conn, pool: Database.Pool) -> Result[Bond.Conn]
  name = try Database.with_connection(pool) do |db| Accounts.name(db) end
  ok(Bond.json(conn, 200, JSON.from(manifest_of(name))))
end

# Rails names the app after the account, and "Campfire" before the first run.
def manifest_of(account_name: String) -> Manifest
  small = Routes.account_logo_path(true)
  large = Routes.account_logo_path(false)
  name = account_name
  if name.empty?
    name = DEFAULT_NAME
  end

  Manifest(
    name: name,
    icons: [
      Icon(src: small, type: "image/png", sizes: "192x192", purpose: "any"),
      Icon(src: large, type: "image/png", sizes: "512x512", purpose: "any"),
      Icon(src: large, type: "image/png", sizes: "512x512", purpose: "maskable"),
    ],
    start_url: Routes.HOME,
    display: "standalone",
    scope: Routes.HOME,
    description: DESCRIPTION,
    categories: ["social", "business", "productivity"],
    theme_color: THEME_COLOR,
    background_color: THEME_COLOR,
  )
end

# The browser checks the worker again at each visit, so a new build reaches it at once.
def service_worker(conn: Bond.Conn) -> Bond.Conn
  typed = Bond.header(Bond.text(conn, 200, service_worker_script()), "content-type", "text/javascript; charset=utf-8")
  Bond.header(typed, "cache-control", "no-cache")
end

def logo(conn: Bond.Conn, assets_dir: String) -> Result[Bond.Conn]
  icon = LARGE_ICON
  if Bond.query(conn, "size").unwrap_or("") == "small"
    icon = SMALL_ICON
  end

  file = try Path.join([assets_dir, icon])
  sent = Bond.send_file(Bond.header(conn, "cache-control", LOGO_CACHE_CONTROL), file)
  return ok(Bond.text(conn, 404, Routes.MISSING)) if not sent.ok?

  sent
end

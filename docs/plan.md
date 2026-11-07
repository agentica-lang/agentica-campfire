# Campfire in Agentica: what is missing

Sources (2026-11-02): basecamp/once-campfire at ca9b963, agentica master b670a2e8 (0.20.0 + regex,
before EAG), bond origin/main and agentica-db origin/main (0.3.0). Size: S = one PR, M = 2-4 PRs, L = 5+ PRs or a new subsystem.

Campfire is MIT (`MIT-LICENSE`): its CSS (27 files, 3.4k lines), Stimulus JS (39 controllers, 1.7k lines) and
SVGs can be reused with the notice kept. The upstream README counts 5.5 KLOC of backend. The suite
basecamp/once-campfire-verification (linked in the upstream README) is the natural acceptance test; I did not read it.

## 1. Feature table

Where: LANG = language/VM, STD = agentica std/, BOND, DB = agentica-db, APP = the new repo.

| Feature (Campfire path) | Today in Agentica | Status | Where | Size |
|---|---|---|---|---|
| Rooms open/closed/direct, memberships, involvement levels (`app/models/room.rb`, `rooms/*.rb`, `membership.rb`) | plain SQL + structs, Bond router | exists | APP | M |
| Messages, pagination by id, edit/delete, client_message_id (`messages_controller.rb`, `message/pagination.rb`) | same | exists | APP | M |
| Real-time Turbo Streams over Action Cable (`message/broadcasts.rb`, `app/channels/*.rb`, `config/cable.yml`) | WebSocket server in std/http (`HTTP.listen_websocket`, 0.20.0), typed channels | partial: no hub, not in Bond, no unified handler (gap 1) | STD, BOND, APP | L |
| Presence, heartbeat, typing (`presence_channel.rb`, `membership/connectable.rb` TTL 60 s, `typing_notifications_channel.rb`) | ATS counters, Task.sleep | exists | APP | S |
| Unread + badge + unread fan-out (`room.rb#unread_memberships`, `unread_rooms_channel.rb`, `jobs/message/broadcast_unread_room_job.rb`) | ATS + SQL | exists | APP | S |
| Web Push, VAPID (`lib/web_push/*.rb`, `models/push/subscription.rb`, `room/message_pusher.rb`, `config/initializers/vapid.rb`, `pwa/service_worker.js`) | HMAC, SHA, Base64url, SecureRandom, HTTP client over TLS; FFI (Bytes in, out params, owned buffers, resources) | partial. Maintainers' decision: crypto stays out of the core, done by FFI to system libcrypto in the Campfire repo or a small package; today's FFI looks sufficient (section 5), to be proved by a spike | APP or package (FFI), no core change | M |
| Uploads (`has_one_attached :attachment`, `config/storage.yml` Disk) | `HTTP.listen_upload` (Channel[Bytes]), `File.write_bytes`, `File.sha256`, `Bond.send_file` with ranges | partial: no multipart parser, upload not in Bond, upload and stream and WS cannot share one server | STD, BOND, APP | M |
| Image/video previews (`message/attachment.rb`: thumb 1200x800, webp poster, 250M-pixel cap; `lib/rails_ext/time_limited_video_previewer.rb`; Dockerfile installs libvips, ffmpeg) | `Process.spawn_captured`, FFI, Zlib | missing: no decoder/resizer, no image metadata | APP (+ external tool) | M |
| Avatars 512 webp, account logo 192/512 PNG (`user/avatar.rb`, `accounts/logos_controller.rb`) | same as above | missing (same fix) | APP | S |
| Link unfurling / OpenGraph (`unfurl_links_controller.rb` 10 s deadline, `opengraph/*.rb`, `lib/restricted_http/private_network_guard.rb`) | HTTP client with redirects off, std/regex | partial: no DNS resolve, no connect-by-IP, no private-range guard, no HTML meta parser | STD, APP | M |
| Search (`message/searchable.rb`, FTS5 `message_search_index` porter in `db/schema.rb`, `searches_controller.rb`) | SQLite via FFI, any SQL runs | partial: needs FTS5 in the system libsqlite3 (unverified) | DB, APP | S |
| @mentions (`user/mentionable.rb`, `message/mentionee.rb`, `autocompletable/users_controller.rb`) | std/regex, JSON | exists if plain text; rich text needs sanitizer | APP | S |
| Rich text editor (Lexxy / Action Text, `lib/rails_ext/action_text_allowed_tags.rb`, `helpers/content_filters/*`) | `HTML.escape` only | sanitizer and autolink exist (`html_sanitizer.agc`, `autolink.agc`); missing: the editor script and toolbar | STD, APP | M |
| Boosts (`models/boost.rb`, `messages/boosts_controller.rb`) | SQL | exists | APP | S |
| Bots API + webhooks (`user/bot.rb` key `id-token`, `messages/by_bots_controller.rb`, `webhook.rb` 7 s timeout, `jobs/bot/webhook_job.rb`) | HTTP.post with timeout, Bond routes, SecureRandom | exists | APP | S |
| Auth: sessions, bcrypt, rate limit 10/3 min, signed cookie, CSRF header-only (`sessions_controller.rb`, `concerns/authentication.rb`, `session.rb`, `user.rb`) | scrypt/PBKDF2, HMAC + `secure_compare`, std/cookie, Bond cookies | exists: Bond cookie sessions, `Bond.csrf` (Sec-Fetch-Site and Origin) and `Conn.remote_addr`; the rate limit is built per IP, 10 sign-in posts in 3 minutes (`src/campfire/rate_limit.agc`) | BOND, STD | M |
| Invite link, first-run wizard, roles, bans by IP (`account/joinable.rb`, `first_runs_controller.rb`, `user/role.rb`, `user/bannable.rb`, `block_banned_requests.rb`) | SecureRandom | exists; bans by IP use `Conn.remote_addr` | APP, STD | S |
| Session transfer by QR (`sessions/transfers_controller.rb`, `user/transferable.rb`, `qr_code_controller.rb`, rqrcode) | HMAC tokens | missing: QR encoder (or draw it client-side in JS) | APP | S |
| DB: SQLite, WAL, 13 tables, FTS5 (`db/schema.rb`, `config/database.yml`, `initializers/sqlite_wal_checkpoint.rb`) | agentica-db `Db`/`Orm`, sqlite adapter (busy timeout 5 s, BEGIN IMMEDIATE) | partial: a connection is owned by one task, so the app lends them from a `DbPool` (one per request); a migrations runner exists | DB | M |
| Background jobs (resque + Redis, 6 jobs in `app/jobs/`) | Task, Channel, Task.map | exists in-process (not durable) | APP | S |
| Redis use (Action Cable pub/sub, kredis, resque, rate limits) | ATS tables, Channel | replace: ATS for counters/presence/rate/cache, a hub task for fan-out | APP | M |
| Caching (`response_cache.rb`, `fragment_cache.rb`, `record_cache.rb`, ETag in `messages_controller.rb`) | ATS, `Digest.sha256` | exists; Bond has no ETag/304 | BOND, APP | S |
| Compression + static caching (Thruster) | `Zlib.gzip`, `Bond.static` (no cache headers) | partial | BOND | S |
| PWA (`pwa_controller.rb`, manifest, service worker) | static files, views | exists | APP | S |
| Assets (importmap, Propshaft, Stimulus, CSS, sounds) | `Bond.static`, `Bond.send_file` | maintainers' decision: esbuild + dart-sass via Makefile/Dockerfile; needs fingerprinted names + cache headers | APP, BOND | M |
| Views (47 ERB files, 2.3k lines, Turbo Streams, partials) | EAG in progress (`<<~EAG`, `<%= %>`, output is a plain String, raw) | in progress | LANG | M |
| Dates/time (JS `local_time_controller` renders local time) | `Time.now_ms` only | missing server formatting (ISO 8601, UTC civil date) | STD | S |
| Deploy: Docker, Thruster, TLS via Let's Encrypt (`Dockerfile`, `Procfile`, `docs/self-hosting.md`: TLS_DOMAIN, DISABLE_SSL, `/rails/storage`) | static release binary, `HTTP.listen_tls` (PEM files) | partial: no ACME | APP, STD | M |
| Admin scripts (`script/admin/generate-secrets`, `create-vapid-key`, `prepare-backup`, `reset-password`) | `agentica FILE` programs, SQLite `.backup`/VACUUM INTO | exists; VAPID key needs EC keygen | APP | S |

## 2. How Agentica maps the infrastructure

- Redis goes away. The maintainers' decision (ATS instead of Redis) holds with one catch: an `ATS` value
  cannot hold a `Channel` or `Fn` (`site/content/library/concurrency/ats.md`, `CHECK-ATS-VALUE`). So
  fan-out cannot be "ATS of subscribers". Use one hub task that owns `Map[room, List[Channel]]` and receives
  subscribe/unsubscribe/publish on a `Channel`. ATS stays for counters, presence, unread flags, rate
  limits and the response cache.
- Single process, many schedulers: ATS is atomic across schedulers, so no Redis is needed for one machine
  (the same limit as Campfire's "single-machine" promise).
- Jobs: a worker pool of Tasks; push and webhooks may be lost on a crash (same as Resque best effort for
  push). Room destroy and ban cleanup should be a SQLite jobs table so they survive a restart.
- Bond: use origin/main, not the `handlers` branch (README of main lists cookies, query/forms, static,
  files, streaming, SSE). Missing there then: websocket, multipart, signed cookies/sessions, CSRF/Origin,
  remote IP, compression, ETag, templates; Bond main has all of these now but compression (`Bond.static` sends
  an ETag, and `Conn.remote_addr` is on main only, not in 0.5.0).

## 3. Blocking gaps, in order (before an MVP)

1. **One server for all handler kinds** (std/http, M). Today `listen`, `listen_stream`, `listen_upload` and
   `listen_websocket` are four separate server kinds (`network.md`, "Handler and middleware"). Campfire
   needs a page, a file download (stream), an upload and a WebSocket on one port. `UpgradeHandler` can only
   `Reply` with a whole `HttpResponse`, so `Bond.send_file` cannot share a server with a WebSocket.
   Fix: one handler type that returns an enum (Response | Stream | Upgrade) and optionally takes the upload
   channel. Workaround for a prototype: a second port behind a path-routing proxy.
2. **`HttpRequest` had no peer address** (std/http, S). Done: `HttpRequest.remote_addr` (Agentica 0.22.0) and
   `Conn.remote_addr` (Bond main, which this repo pins until Bond 0.6.0). The session IP and the per-IP sign-in
   limit and the bans by IP use it.
3. **EAG lands, with an escape policy** (LANG, in progress). Output is raw (`stdlib/eag.agc`: write
   `EAG.html_escape(x)` everywhere). For a chat app one missed escape is stored XSS. Decide before the
   views are written: an auto-escaping `<%= %>` plus a `SafeHtml`-like marker for partials, or a lint/check.
4. **Bond additions** (BOND, M): WebSocket route (wrap `upgrade_only`, check `Origin` as the doc says),
   `multipart/form-data` parser that streams to disk with a size cap, signed cookie/session helpers
   (HMAC exists), `Sec-Fetch-Site`/Origin CSRF check, gzip middleware, ETag/304 and `Cache-Control` for
   `Bond.static`.
5. **agentica-db** (DB, M): a connection pool (done: `DbPool`, one connection per request; a `Handle` belongs to
   the task that opened it, `sqlite.agc` header), a migrations runner (ORM plan item 6 is open), PRAGMAs
   (`journal_mode=WAL`, `foreign_keys=ON`) in `open`, and a startup check that FTS5 is compiled in.
6. **std/time** (STD, S): ISO 8601 / UTC civil date from `Time.now_ms`. §41 (dates) is "planned, not started";
   do only the small helper now.
7. **Realtime hub + Action Cable subset** (APP or a `bond-cable` package, M): see hard part "WebSockets".
8. **Asset pipeline** (APP, S; done: `make assets`, `tools/assets.mjs`): esbuild and dart-sass, fingerprinted output
   committed to `public/assets/` (no Node stage in the Docker image), served by `Bond.static` with long cache headers.

Not blocking an MVP: Web Push, image variants, unfurl, rich text, QR transfer, ACME.

## 4. MVP scope (smallest usable Campfire)

Single account, first-run admin wizard, login/logout, invite link, users list, open and closed rooms and
direct messages, plain-text messages with autolink and @mentions (no rich text), live delivery over
WebSocket (append/remove), presence and typing, unread dots and sounds, search (FTS5), edit/delete own
message, boosts, attachments stored on disk and shown as download links (image shown at original size),
PWA manifest, bots API + webhooks. Docker image with the binary; TLS by a reverse proxy.
Out of the MVP: push, thumbnails, unfurl, rich text, QR transfer, ACME, custom styles, admin logo upload.

## 5. Hard parts

**Web Push crypto (maintainers' decision: FFI to libcrypto, outside the core).** Needs (RFC 8291 aes128gcm + RFC 8292
VAPID): P-256 key generation, ECDH with the subscriber's `p256dh`, HKDF-SHA256, AES-128-GCM (the VM has only
256), ECDSA P-256/SHA-256 for the ES256 JWT (raw 64-byte r||s), base64url (exists). HKDF is two `HMAC.sha256`
calls in Agentica, no FFI. HTTP/2 is not needed: Campfire's gem posts over HTTP/1.1
(`lib/web_push/notification.rb`) and endpoints are host-allowlisted (`models/push/subscription.rb`), so the
Agentica HTTP client and no DNS pinning are enough.
- A. FFI to `libcrypto.so.3` (OpenSSL 3, present in Debian 12/Ubuntu 22+ images) in `campfire/src/webpush/`, later
  a package `agentica-lang/webpush` if another app wants it. **Recommended** (maintainers' decision). M: one extern
  block of ~15 functions, a DER helper, tests with RFC 8291 section 5 and RFC 8292 vectors, plus a Node or
  Python `cryptography` peer.
- B. C builtins in the VM: rejected by the maintainers for now (keeps the core small).
- C. Pure Agentica P-256: needs bigints and constant-time code. Reject.
What the FFI must support, and whether it does today (`site/content/library/io-and-system/native/types.md`):
1. Byte buffers in: `C.Bytes` params (copy, per call). Yes. Out: `Native.memory_pointer(n)` owned buffer,
   read with `Native.get_bytes`. Yes (free on block end).
2. Opaque handles with a free function: `resource Key, free: EVP_PKEY_free` (also `EVP_PKEY_CTX_free`,
   `EVP_CIPHER_CTX_free`). Yes; out resources work for `EVP_EC_gen`-style results.
3. Out parameters: `out` slots are zeroed and returned as a record field. Yes for `int *outl`, `size_t *`
   and `EVP_PKEY **`. Limit: an in/out `size_t*` (`EVP_PKEY_derive`, `EVP_PKEY_sign` take the buffer size in)
   cannot be an `out` param (it starts at 0); use an 8-byte owned buffer with `put_int64`/`get_int64`.
4. Pointer to pointer in (`d2i_PUBKEY(NULL, const unsigned char **pp, len)`): build with
   `Native.put_pointer` into an owned buffer, and read the moved pointer back. Yes.
5. `size_t` and `uint64` as `C.Int64`, enum constants as module constants, and the fixed `EVP_EC_gen("P-256")`
   instead of the variadic `EVP_PKEY_Q_keygen` (variadics work too, #619). Yes.
6. Long calls: ECDH and ECDSA take ~0.1 ms; a plain `def` blocks the other tasks (it runs under `rt->sync`),
   so declare them `compute def` and fan out a push to many subscriptions with `Task.map`.
7. No struct passing is needed: skip `OSSL_PARAM`/`EVP_PKEY_fromdata`. Import the subscriber's raw 65-byte
   point by prefixing the fixed 26-byte P-256 SPKI header and calling `d2i_PUBKEY`; export ours with
   `EVP_PKEY_get_octet_string_param(key, "pub", ...)`; load the VAPID private scalar by wrapping it in a SEC1
   `ECPrivateKey` DER (`d2i_PrivateKey`, built with Bytes concat); sign the digest with
   `Digest.sha256` + `EVP_PKEY_sign_init`/`EVP_PKEY_sign`, then convert DER (r,s) to raw r||s in Agentica.
   AES-128-GCM: `EVP_EncryptInit_ex` (key and iv as `C.Bytes`), `EVP_EncryptUpdate`, `EVP_EncryptFinal_ex`, and
   `EVP_CIPHER_CTX_ctrl(ctx, 0x10, 16, tagbuf)` with an owned buffer.
Not verified (needs a spike before Phase 5): (a) the release binary links a static OpenSSL, so loading the
system `libcrypto.so.3` puts two OpenSSL copies in one process; check symbol interposition and the
`-rdynamic` setting. (b) that `d2i_PrivateKey` fills the public key from the scalar when the SEC1 `[1]` field
is left out (else embed the public key, which we have). (c) Windows and macOS library names; the app is
Linux-in-Docker, so ignore them. The image needs the `libssl3` package. The library name and version live in
one constant, with a startup check that gives a clear error (the sqlite adapter does the same).
Risk to record: a typo in the extern signature is undefined behavior (the doc says the VM does not check
it), so keep the block small and test every function against RFC vectors.
- Recommend A. Ship the MVP without push; it is the first post-MVP phase, and it needs no change in agentica.

**Image resizing and video posters.**
- A. `Process.spawn_captured` to `vipsthumbnail` and `ffmpeg` (Campfire's image already installs both).
  S. Needs `--deny-run` off and the tools in the Docker image.
- B. FFI to libvips (`vips_thumbnail_buffer`, GObject memory with `g_free`). M, no process cost.
- C. Parse headers only (PNG/JPEG/GIF/WebP width and height in Agentica, S) and send originals; resize in
  the browser (`max-width`). No server variants.
- Recommend C for the MVP (needed anyway for layout size and the pixel cap), A in the attachments phase,
  B only if profiling asks.

**WebSockets (Turbo Streams).** The server side exists; the browser side is the cost. Campfire's JS calls
`cable.subscribeTo(...)` (`presence_controller.js`, `typing_notifications_controller.js`).
- A. Implement the Action Cable JSON protocol subset (`actioncable-v1-json` subprotocol, `welcome`, ping every
  3 s, subscribe/confirm/reject/unsubscribe, `message` with `perform` actions) on `HTTP.WebSocket`. About
  300 lines; the unmodified `@rails/actioncable` and `turbo-rails` JS (bundled by esbuild) keep working,
  which saves rewriting ~1.7k lines of Stimulus.
- B. Own JSON protocol plus a small Stimulus connector that feeds `Turbo.connectStreamSource`. Smaller
  server, but every channel controller is rewritten.
- C. SSE (`Bond.sse` exists) for server-to-client plus POST for typing/presence. No gap 1 for streams,
  but each tab holds one open request and presence needs polling.
- Recommend A. Fan-out through the hub task; each connection has a bounded `outgoing` channel of 8
  (`network.md`): on overflow drop the socket and let the client resync (Campfire has `refreshes_controller.rb`).

**File storage.**
- A. Disk, like Campfire's Active Storage Disk service: random key, `blobs` table (key, filename,
  content_type, byte_size, checksum), `File.write_bytes`/`File.open` streaming from `listen_upload`,
  `Bond.send_file` for ranges and downloads. S-M plus the multipart parser. Sniff types by magic bytes
  (std/mime is by extension only) and always send `nosniff` and `attachment` for non-images
  (`config/initializers/uploaded_script_guard.rb` does the same job).
- B. Blobs inside SQLite (`Value.Blob`). Simple backup, bad for large files.
- C. S3 over the HTTP client with SigV4 (HMAC exists). M, later.
- Recommend A; backups: SQLite `VACUUM INTO` plus the storage folder (as `script/admin/prepare-backup`).

**Full-text search.**
- A. SQLite FTS5 through agentica-db, same schema as Campfire (`fts5(body, tokenize=porter)`), rows kept in
  sync in the same transaction. S. Risk: the system `libsqlite3` must have FTS5 (Debian/Ubuntu do; I did
  not run it). Pin the Docker base image and check at startup.
- B. In-memory inverted index in ATS rebuilt on boot. S-M, no ranking, memory grows with history.
- C. `LIKE '%q%'`. S, slow on big rooms.
- Recommend A, with C as the startup fallback.

**Other risks.** SSRF for unfurl needs a `TCP.resolve`-style builtin or a client option to connect to a
given IP and to refuse private ranges (STD, M); webhooks are admin-set so Campfire does not guard them.
ACME: reverse proxy for the MVP (Caddy or Traefik); a `std/acme` later would reuse the EC primitives
plus a CSR/DER builder; it can reuse the same libcrypto FFI (L). Naming: "Campfire" is 37signals' product name; this repo is `agentica-campfire` and describes itself as a port; do not ship a binary or image under the bare name "Campfire".

## 6. Phased plan

Phase 0, prerequisites (agentica repo, 5-7 PRs): unified handler kind (gap 1); `remote_addr` (gap 2, done);
EAG lands with the escape policy (gap 3); `std/time` helper (gap 6).

Phase 1, framework (Bond 4-6 PRs, agentica-db 3 PRs): Bond websocket route, multipart, signed cookies and
sessions, CSRF/Origin, gzip/ETag; agentica-db pool or owner-task helper, migrations, WAL/FTS5 check.

Phase 2, app skeleton (this repo, `agentica-lang/agentica-campfire`, 6-8 PRs): repo layout + Makefile + Dockerfile,
esbuild/sass pipeline with copied CSS/JS (MIT notice), schema and migrations, first run, auth, rooms,
messages with EAG views, BDD features first (as in the other org repos).

Phase 3, realtime (campfire repo + maybe `bond-cable`, 4-5 PRs): hub task, Action Cable subset, Turbo
Stream rendering of partials, presence, typing, unread, sounds. This is the MVP line.

Phase 4, content (campfire, 5 PRs; agentica 1-2): attachments on disk, image header parser, mentions,
boosts, search, bots and webhooks, avatars. Optional ffmpeg/vips tools.

Phase 5, push (campfire repo only, 4-5 PRs, no core change): FFI spike for libcrypto (gap (a) above), `webpush`
module (ECDH, HKDF, AES-128-GCM, VAPID JWT) with RFC vectors, service worker, subscription endpoints, VAPID
key script, delivery with `Task.map`. Move it to a package only if a second app needs it.

Phase 6, polish (mixed): unfurl with SSRF-safe fetch, sanitizer + rich text (Lexxy), QR transfer, ACME
(optional), `once-campfire-verification` run, benchmark against the table in the upstream README, ONCE-style image.

// The browser check of the room page script (`public/assets/campfire-DIGEST.js`): the local time of the messages, the
// pages that load when the reader scrolls (older above, newer below on a page at a cursor) and the reading position that
// stays where it is when the list changes. It is not part of `make test` or of CI, which have no browser: run it by hand
// after a change to the script.
//
//   CAMPFIRE_SESSION_SECRET=... CAMPFIRE_PORT=3592 CAMPFIRE_DATA_DIR=/tmp/room agentica campfire.agc
//   BASE=http://127.0.0.1:3592 CHROMIUM=/usr/bin/chromium PLAYWRIGHT_CORE=playwright-core node tools/room_check.js
//
// It needs a new database (it makes the first admin, "ana@example.com"), `playwright-core` and a Chromium, as
// `keys_check.js` does. It adds 130 messages to room 1 and exits 1 when a check fails. With DATA_DIR (the data folder of
// the app, node 22.5 or later for `node:sqlite`) it also makes a room whose ids are not in the order of time, as a
// database that Rails seeded can have.
const { chromium } = require(process.env.PLAYWRIGHT_CORE || "playwright-core");
const base = process.env.BASE || "http://127.0.0.1:3592";
const PASSWORD = "correct horse battery";
let failed = 0;
function check(name, ok, extra) { console.log((ok ? "PASS " : "FAIL ") + name + (ok ? "" : " " + (extra || ""))); if (!ok) failed++; }

async function signIn(page) {
  await page.goto(base + "/");
  if (page.url().includes("first_run")) {
    await page.fill('input[name="name"]', "Ana");
    await page.fill('input[name="email"]', "ana@example.com");
  } else if (page.url().includes("session/new")) {
    await page.fill('input[name="email_address"]', "ana@example.com");
  }
  if (!page.url().endsWith("/rooms/1")) {
    await page.fill('input[name="password"]', PASSWORD);
    await Promise.all([page.waitForNavigation(), page.click('button[type="submit"]')]);
  }
}

// Posts a message the way the composer does, so every page that listens hears it.
const post = (page, text) => page.evaluate(async (t) => {
  const response = await fetch("/rooms/1/messages", {
    method: "POST",
    credentials: "same-origin",
    headers: { Accept: "text/vnd.turbo-stream.html", "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" },
    body: new URLSearchParams({ "message[body]": t }),
  });
  return response.status;
}, text);

const count = (page) => page.locator("[data-message-id]").count();
const ids = (page) => page.$$eval("[data-message-id]", (items) => items.map((i) => parseInt(i.dataset.messageId, 10)));
// The scroller is column-reverse: -scrollTop is the distance from the newest end.
const toTop = (page) => page.evaluate(() => { const s = document.querySelector(".scroller"); s.scrollTop = -(s.scrollHeight - s.clientHeight); });
const toEnd = (page) => page.evaluate(() => { document.querySelector(".scroller").scrollTop = 0; });
// Where a message sits in the view, from the top edge of the scroller.
const place = (page, id) => page.evaluate((n) => document.getElementById("message_" + n).getBoundingClientRect().top - document.querySelector(".scroller").getBoundingClientRect().top, id);
const settle = (page) => page.waitForTimeout(600);

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || "/usr/bin/chromium", args: ["--no-sandbox"] });
  const context = await browser.newContext({ locale: "en-US", timezoneId: "Asia/Tokyo", viewport: { width: 1000, height: 700 } });
  // The sockets of the pages, so that a check can drop one and make the page reconnect.
  await context.addInitScript(() => {
    const Socket = window.WebSocket;
    window.__sockets = [];
    // With `__down` set a connection goes to a port that refuses it, so the page cannot reconnect until it is cleared.
    window.WebSocket = function (url, ...rest) { const one = new Socket(window.__down ? "ws://127.0.0.1:9/cable" : url, ...rest); window.__sockets.push(one); return one; };
    window.WebSocket.prototype = Socket.prototype;
  });
  const page = await context.newPage();
  await signIn(page);
  await page.goto(base + "/rooms/1");
  const have = await count(page);
  for (let n = have; n < 130; n++) {
    await post(page, `message number ${n + 1}, a little longer than the shortest line so that a page is more than a screen`);
  }
  await page.goto(base + "/rooms/1");
  const all = await page.evaluate(() => fetch("/rooms/1/messages?after=0").then((r) => r.status));
  check("after=0 is a page of the room", all === 200 || all === 204);

  // Local time: Tokyo is UTC+9, so the clock of the page is not the UTC clock the server wrote.
  const stamp = await page.locator("[data-message-id] time").last().evaluate((t) => ({ iso: t.getAttribute("datetime"), text: t.textContent, title: t.title }));
  const want = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", timeZone: "Asia/Tokyo" }).format(new Date(stamp.iso));
  check("the time is the clock of the viewer", stamp.text === want, JSON.stringify([stamp, want]));
  check("the time of today has no date", !/\b20\d\d\b/.test(stamp.text), stamp.text);
  check("the title has the date and the time", /\b20\d\d\b/.test(stamp.title) && stamp.title.includes(want), stamp.title);
  const old = await page.evaluate(() => {
    const t = document.createElement("time");
    t.setAttribute("datetime", "2020-01-02T20:04:05.000Z");
    t.textContent = "20:04";
    const holder = document.createElement("span");
    holder.append(t);
    document.querySelector('[id^="messages_rooms_"] [data-message-id] h3').append(holder);
    return new Promise((done) => setTimeout(() => done(t.textContent), 50));
  });
  check("a time of another day has its date, in the zone of the viewer", old === "Jan 3, 2020, 5:04 AM", old);
  // Two times that come in together, the first with no valid instant: it keeps its text and the second is still localized
  // (a formatter that is given an invalid date throws, which would end the pass over the times).
  const bad = await page.evaluate(() => {
    const holder = document.createElement("span");
    const broken = document.createElement("time");
    broken.setAttribute("datetime", "not a time");
    broken.textContent = "20:04";
    const fine = document.createElement("time");
    fine.setAttribute("datetime", "2020-01-02T20:04:05.000Z");
    holder.append(broken, fine);
    document.querySelector('[id^="messages_rooms_"] [data-message-id] h3').append(holder);
    const bare = document.createElement("time");
    bare.setAttribute("datetime", "2020-01-02T20:04:05.000Z");
    document.querySelector('[id^="messages_rooms_"] [data-message-id] h3').append(bare);
    return new Promise((done) => setTimeout(() => done([broken.textContent, fine.textContent, bare.textContent]), 50));
  });
  check("a time with no valid instant keeps the server's text", bad[0] === "20:04", bad[0]);
  check("a time after it is still localized", bad[1] === "Jan 3, 2020, 5:04 AM", bad[1]);
  check("a <time> that is added by itself is localized", bad[2] === "Jan 3, 2020, 5:04 AM", bad[2]);

  // A person who is signed out: the answer to a page of older messages is the sign-in page after a redirect, which the
  // list must not take in, and which is not asked for again and again.
  const out = await browser.newContext({ locale: "en-US", viewport: { width: 1000, height: 700 } });
  const gone = await out.newPage();
  await signIn(gone);
  await gone.goto(base + "/rooms/1");
  await out.clearCookies();
  let asked = 0;
  gone.on("request", (request) => { if (request.url().includes("/rooms/1/messages?")) asked++; });
  await toTop(gone);
  await gone.waitForTimeout(1500);
  check("a signed-out answer adds nothing to the list", (await count(gone)) === 40 && (await gone.locator('.scroller input[type="password"]').count()) === 0);
  check("a signed-out answer is asked for once, and the link stays", asked === 1 && (await gone.locator(".thread > .more a").count()) === 1, asked);
  await out.close();

  // Scroll paging: 130 messages are three pages. The reader's place stays when the older ones come.
  check("the page starts with the newest 40", (await count(page)) === 40);
  const first = (await ids(page))[0];
  // Read at the top in the same task as the scroll, before the answer of the server comes.
  const atTop = await page.evaluate((id) => {
    const s = document.querySelector(".scroller");
    s.scrollTop = -(s.scrollHeight - s.clientHeight);
    return document.getElementById("message_" + id).getBoundingClientRect().top - s.getBoundingClientRect().top;
  }, first);
  await page.waitForFunction(() => document.querySelectorAll("[data-message-id]").length === 80);
  await settle(page);
  check("older messages load at the top", (await count(page)) === 80);
  check("the reader's place stays when they do", Math.abs((await place(page, first)) - atTop) < 2, `${atTop} -> ${await place(page, first)}`);
  const link = await page.locator(".thread > .more a").getAttribute("href");
  check("the link of the fallback points before the first message", link === `/rooms/1?before=${(await ids(page))[0]}`, link);
  await toTop(page);
  await page.waitForFunction(() => document.querySelectorAll("[data-message-id]").length === 120);
  await toTop(page);
  await page.waitForFunction(() => document.querySelectorAll("[data-message-id]").length === 130);
  await toTop(page);
  await page.waitForFunction(() => document.querySelectorAll(".thread > .more").length === 0);
  check("the link goes away when there is nothing older", (await page.locator(".thread > .more").count()) === 0);
  const sorted = await ids(page);
  check("the messages are in order, none twice", sorted.every((v, i) => i === 0 || v > sorted[i - 1]));

  // Keeping the place: a message heard while the reader is up there does not move the view; at the end it sticks.
  // A second window of the same person, in a context of its own, so that both pages are drawn and hear each other.
  const second = await browser.newContext({ locale: "en-US", timezoneId: "Asia/Tokyo" });
  const other = await second.newPage();
  await signIn(other);
  await other.goto(base + "/rooms/1");
  await page.evaluate(() => { document.querySelector(".scroller").scrollTop = -1500; });
  await settle(page);
  const mid = await page.evaluate(() => {
    const s = document.querySelector(".scroller").getBoundingClientRect();
    const hit = [...document.querySelectorAll("[data-message-id]")].find((i) => i.getBoundingClientRect().top > s.top + 100);
    return hit.dataset.messageId;
  });
  const before = await place(page, mid);
  await post(other, "heard while reading up");
  await page.waitForFunction((n) => document.querySelectorAll("[data-message-id]").length === n + 1, 130);
  await settle(page);
  check("a live message does not move a reader who is up", Math.abs((await place(page, mid)) - before) < 2, `${before} -> ${await place(page, mid)}`);
  await toEnd(page);
  await post(other, "heard at the end");
  await page.waitForFunction((n) => document.querySelectorAll("[data-message-id]").length === n + 1, 131);
  await settle(page);
  const stuck = await page.evaluate(() => -document.querySelector(".scroller").scrollTop);
  check("a reader at the end stays at the end", stuck < 2, stuck);
  await page.evaluate(() => { document.querySelector(".scroller").scrollTop = -60; });
  await settle(page);
  await post(other, "heard near the end");
  await page.waitForFunction((n) => document.querySelectorAll("[data-message-id]").length === n + 1, 132);
  await settle(page);
  check("a reader within 100px of the end is taken to it", (await page.evaluate(() => -document.querySelector(".scroller").scrollTop)) < 2);

  // A page at a cursor: the newer ones load below it, the place stays, and at the end the page is the latest one.
  const target = sorted[69];
  await page.goto(base + `/rooms/1?before=${target}`);
  check("the page at a cursor has the link to the latest", (await page.locator('.thread > .more a[href="/rooms/1"]').count()) === 1);
  await page.waitForFunction(() => document.querySelectorAll("[data-message-id]").length > 40);
  const held = (await ids(page))[39];
  const spot = await place(page, held);
  await settle(page);
  check("the newer messages load below and the place stays", Math.abs((await place(page, held)) - spot) < 2, `${spot} -> ${await place(page, held)}`);
  for (let n = 0; n < 6 && (await page.locator('.thread > .more a[href="/rooms/1"]').count()); n++) {
    await toEnd(page);
    await settle(page);
  }
  check("the link to the latest goes away at the newest message", (await page.locator('.thread > .more a[href="/rooms/1"]').count()) === 0);
  const newest = await page.evaluate(() => fetch("/rooms/1").then((r) => r.text()).then((t) => {
    const found = [...t.matchAll(/data-message-id="(\d+)"/g)].map((m) => parseInt(m[1], 10));
    return Math.max(...found);
  }));
  check("the page holds the room up to the newest message", (await ids(page)).at(-1) === newest, `${(await ids(page)).at(-1)} ${newest}`);
  const n = await count(page);
  await post(other, "after the page reached the end");
  await page.waitForFunction((k) => document.querySelectorAll("[data-message-id]").length === k + 1, n, { timeout: 5000 }).then(
    () => check("a live message is appended once the page is the latest", true),
    () => check("a live message is appended once the page is the latest", false),
  );

  // The reconnect of a page that walked down from a cursor: its list is not the page at its address any more, and the
  // catch-up must neither remove the messages after the cursor nor miss the one that came while the socket was away. The
  // message is posted while the socket is down for good (the page cannot reconnect until `__down` is cleared).
  const kept = await ids(page);
  await page.evaluate(() => { window.__down = true; window.__sockets.forEach((one) => one.close()); });
  await page.waitForFunction(() => window.__sockets.every((one) => one.readyState === 3));
  await post(other, "missed while the socket was away");
  await page.waitForTimeout(400);
  check("the message is missed while the socket is down", (await count(page)) === kept.length);
  await page.evaluate(() => { window.__down = false; });
  await page.waitForFunction((k) => document.querySelectorAll("[data-message-id]").length === k + 1, kept.length, { timeout: 15000 }).then(
    async () => {
      const now = await ids(page);
      check("a reconnect keeps what the page has and brings the missed message", kept.every((v, i) => now[i] === v) && now.length === kept.length + 1);
    },
    async () => check("a reconnect keeps what the page has and brings the missed message", false, (await count(page)) + " of " + (kept.length + 1)),
  );

  // What the pager does when the server fails. Each case loads the room again (40 messages, an older link) and reaches for
  // the top; `times` are the moments of the requests for the older page.
  const OLDER = "**/rooms/1/messages?before=*";
  async function reach(handler) {
    await page.unroute(OLDER).catch(() => {});
    const times = [];
    await page.route(OLDER, (route) => { times.push(Date.now()); return handler(route, times.length); });
    await page.goto(base + "/rooms/1");
    await toTop(page);
    return times;
  }
  const loaded = (n, ms) => page.waitForFunction((k) => document.querySelectorAll("[data-message-id]").length === k, n, { timeout: ms || 10000 }).then(() => true, () => false);

  let times = await reach((route, n) => (n === 1 ? route.fulfill({ status: 503, body: "busy" }) : route.continue()));
  check("a 503 is tried again, and the page comes", (await loaded(80)) && times.length === 2 && times[1] - times[0] >= 1800, JSON.stringify(times));

  times = await reach((route, n) => (n === 1 ? route.fulfill({ status: 429, headers: { "Retry-After": "3" }, body: "slow down" }) : route.continue()));
  check("a 429 is tried again after the Retry-After, and the page comes", (await loaded(80)) && times.length === 2 && times[1] - times[0] >= 2900, JSON.stringify(times));

  times = await reach((route) => route.fulfill({ status: 404, body: "gone" }));
  await page.waitForTimeout(3000);
  check("a refusal that will not change is asked for once", times.length === 1 && (await page.locator(".thread > .more a").count()) === 1, times.length);

  times = await reach((route) => route.fulfill({ status: 503, body: "busy" }));
  await page.waitForTimeout(15000);
  const dead = times.length;
  check("a failing server is asked for 4 times and then left alone, the link stays", dead === 4 && (await count(page)) === 40 && (await page.locator(".thread > .more a").count()) === 1, dead);
  await page.unroute(OLDER);
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  check("the pager wakes when the browser is online again", await loaded(80, 5000));

  times = await reach((route) => route.fulfill({ status: 503, body: "busy" }));
  await page.waitForTimeout(15000);
  await page.unroute(OLDER);
  await page.evaluate(() => { document.querySelector(".scroller").scrollTop = -2000; });
  await settle(page);
  check("it stays asleep while the link is far", (await count(page)) === 40);
  await toTop(page);
  check("it wakes when the reader scrolls to the link", await loaded(80, 5000));

  await page.goto(base + "/rooms/1");
  const copy = await page.evaluate(() => document.querySelector("[data-message-id]").outerHTML);
  times = await reach((route) => route.fulfill({ status: 200, contentType: "text/html", body: copy }));
  await page.waitForTimeout(1500);
  check("a page with nothing new takes the link away and is not asked for again", times.length === 1 && (await count(page)) === 40 && (await page.locator(".thread > .more").count()) === 0, times.length);
  await page.unroute(OLDER);

  // The anchor of the keeper is replaced (an edit does it) while a message comes in below it: the same id is found again.
  await page.goto(base + "/rooms/1");
  await page.evaluate(() => { document.querySelector(".scroller").scrollTop = -1500; });
  await settle(page);
  const shifted = await page.evaluate(async () => {
    const edge = document.querySelector(".scroller").getBoundingClientRect().top;
    const list = document.querySelector('[id^="messages_rooms_"]');
    const anchor = [...list.children].find((item) => item.getBoundingClientRect().bottom > edge);
    const was = anchor.getBoundingClientRect().top - edge;
    anchor.replaceWith(anchor.cloneNode(true));
    const tall = document.createElement("div");
    tall.style.height = "120px";
    list.append(tall);
    await new Promise((done) => setTimeout(done, 300));
    const now = document.getElementById(anchor.id).getBoundingClientRect().top - edge;
    tall.remove();
    return [was, now];
  });
  check("the view keeps its place when the message at its top is replaced", Math.abs(shifted[0] - shifted[1]) < 2, JSON.stringify(shifted));

  // The end of an `after` walk. The page `?before=LAST` has one message to walk to; the answer to the second `after` (the
  // 204) is held, as the server gave it, while a message is made, and then handed over.
  async function walk(duringHold) {
    await page.unroute("**/rooms/1/messages?after=*").catch(() => {});
    await post(other, "short");
    const newest = await page.evaluate(() => fetch("/rooms/1").then((r) => r.text()).then((t) => Math.max(...[...t.matchAll(/data-message-id="(\d+)"/g)].map((m) => parseInt(m[1], 10)))));
    let hits = 0;
    let held = null;
    await page.route("**/rooms/1/messages?after=*", async (route) => {
      hits++;
      const response = await route.fetch();
      if (hits === 2) held = await duringHold();
      await route.fulfill({ response });
    });
    await page.goto(base + `/rooms/1?before=${newest}`);
    await page.waitForFunction(() => !document.querySelector('.thread > .more a[href="/rooms/1"]'), null, { timeout: 10000 });
    await settle(page);
    await page.unroute("**/rooms/1/messages?after=*");
    return held;
  }

  await walk(() => post(other, "created while the last page was in flight"));
  check("what is created while the walk ends is fetched by the catch-up", (await page.locator("text=created while the last page was in flight").count()) === 1);

  const spot2 = await walk(async () => {
    await page.evaluate(() => { document.querySelector(".scroller").scrollTop = -250; });
    await page.waitForTimeout(300);
    return page.evaluate(() => {
      const edge = document.querySelector(".scroller").getBoundingClientRect().top;
      const item = [...document.querySelectorAll("[data-message-id]")].find((i) => i.getBoundingClientRect().top > edge + 30);
      return { id: item.id, at: item.getBoundingClientRect().top - edge };
    });
  });
  const now2 = await page.evaluate((id) => document.getElementById(id).getBoundingClientRect().top - document.querySelector(".scroller").getBoundingClientRect().top, spot2.id);
  check("the view keeps its place when the link to the latest goes away", Math.abs(now2 - spot2.at) < 2, `${spot2.at} -> ${now2}`);

  // A message that is the cursor of the pager is deleted: the room answers 204 for a message it does not have, which is not
  // the end. Both walks ask again from the neighbour.
  const remove = (id) => other.evaluate((n) => fetch("/rooms/1/messages/" + n, { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" }, body: new URLSearchParams({ _method: "delete" }) }).then((r) => r.status), id);
  const roomIds = () => page.evaluate(() => fetch("/rooms/1").then((r) => r.text()).then((t) => [...t.matchAll(/data-message-id="(\d+)"/g)].map((m) => parseInt(m[1], 10))));
  // The page `?before=AFTER` ends at the message CURSOR, more than 40 messages below the newest, so nothing but the pager
  // brings the messages after it (the catch-up of the end of a walk could only show the newest 40). CURSOR is deleted
  // as the first request for what is after it is in flight.
  const newest40 = await roomIds();
  const middle = await page.evaluate((id) => fetch("/rooms/1/messages?before=" + id).then((r) => r.text()).then((t) => [...t.matchAll(/data-message-id="(\d+)"/g)].map((m) => parseInt(m[1], 10))), newest40[0]);
  const cursor = middle.at(-5);
  const after = middle.at(-4);
  let deleted = 0;
  await page.route("**/rooms/1/messages?after=*", async (route) => {
    if (++deleted === 1) await remove(cursor);
    await route.continue();
  });
  await page.goto(base + `/rooms/1?before=${after}`);
  // The reader scrolls down as each page comes, since the place is kept and the link goes below the view.
  for (let n = 0; n < 8 && (await page.locator('.thread > .more a[href="/rooms/1"]').count()); n++) {
    await toEnd(page);
    await settle(page);
  }
  await page.unroute("**/rooms/1/messages?after=*");
  const walked = await ids(page);
  check("a deleted cursor does not end the walk down: the message after it comes, in order", walked.includes(after) && walked.every((v, i) => i === 0 || v > walked[i - 1]), `after ${after} cursor ${cursor}: ${JSON.stringify(walked)}`);

  await page.goto(base + "/rooms/1");
  const top = (await ids(page))[0];
  let dropped = 0;
  await page.route(OLDER, async (route) => {
    if (++dropped === 1) await remove(top);
    await route.continue();
  });
  await toTop(page);
  await page.waitForFunction(() => document.querySelectorAll("[data-message-id]").length > 60, null, { timeout: 10000 }).then(
    async () => check("a deleted first message does not end the walk up, and the link stays", (await page.locator(".thread > .more").count()) === 1),
    async () => check("a deleted first message does not end the walk up, and the link stays", false, await count(page)),
  );
  await page.unroute(OLDER);

  // 45 messages are made while the socket is down for good: the catch-up fetches the newest 40, which have nothing in
  // common with the list. The list becomes that page, in order, with a link to what is before it, and paging up reaches
  // the message that the list had.
  await page.goto(base + "/rooms/1");
  const known = (await ids(page)).at(-1);
  await page.evaluate(() => { window.__down = true; window.__sockets.forEach((one) => one.close()); });
  await page.waitForFunction(() => window.__sockets.every((one) => one.readyState === 3));
  for (let n = 0; n < 45; n++) await post(other, `missed number ${n}`);
  await page.evaluate(() => { window.__down = false; });
  await page.waitForFunction((k) => [...document.querySelectorAll("[data-message-id]")].some((i) => parseInt(i.dataset.messageId, 10) > k + 40), known, { timeout: 15000 });
  await settle(page);
  const jumped = await ids(page);
  check("a catch-up with nothing in common makes the list the newest page, in order", jumped.length === 40 && jumped.every((v, i) => i === 0 || v > jumped[i - 1]) && jumped.at(-1) === (await roomIds()).at(-1), JSON.stringify(jumped));
  const older = await page.locator(".thread > .more a").getAttribute("href");
  check("it has a link to what is before it", older === `/rooms/1?before=${jumped[0]}`, older);
  await toTop(page);
  await page.waitForFunction((k) => [...document.querySelectorAll("[data-message-id]")].some((i) => parseInt(i.dataset.messageId, 10) === k), known, { timeout: 10000 }).then(
    async () => {
      const filled = await ids(page);
      check("paging up reaches the message that the list had, with no gap and none twice", filled.every((v, i) => i === 0 || v > filled[i - 1]) && new Set(filled).size === filled.length);
    },
    () => check("paging up reaches the message that the list had, with no gap and none twice", false),
  );

  // A short newest message: the page that the walk loads is within 100px of the end, and the reader is taken to it.
  await walk(async () => null);
  check("a reader near the end is taken to it when the page becomes the latest", (await page.evaluate(() => -document.querySelector(".scroller").scrollTop)) < 2);

  // A room whose ids are not in the order of time (the id of a database that Rails seeded does not follow it): 60 messages
  // whose ids go down as time goes up. The page loads the 20 older ones, the socket is dropped, and the catch-up has to
  // keep them, though their ids are above the lowest id of the newest 40.
  if (process.env.DATA_DIR) {
    const { DatabaseSync } = require("node:sqlite");
    const room = await page.evaluate(() => fetch("/rooms", { method: "POST", credentials: "same-origin", headers: { "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" }, body: new URLSearchParams({ name: "Backwards" }) }).then((r) => new URL(r.url).pathname.split("/").pop()));
    const db = new DatabaseSync(process.env.DATA_DIR + "/campfire.db");
    db.exec("pragma busy_timeout = 5000");
    for (let i = 0; i < 60; i++) {
      const at = `2026-03-01 10:${String(i).padStart(2, "0")}:00.000000`;
      db.prepare("insert into messages (id, room_id, creator_id, client_message_id, created_at, updated_at) values (?, ?, 1, 'seed', ?, ?)").run(9000 - i, room, at, at);
      db.prepare("insert into action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at) values ('Message', ?, 'body', ?, ?, ?)").run(9000 - i, `<div>seeded ${i}</div>`, at, at);
    }
    db.close();
    await page.goto(base + `/rooms/${room}`);
    check("the page of the room shows the newest 40 by time", (await count(page)) === 40 && (await ids(page))[0] === 8980, (await ids(page))[0]);
    await toTop(page);
    check("older messages load, with ids above the first page's", await loaded(60));
    // The link stays until the server says there is nothing older: with it in the page the pager would load them again.
    await toTop(page);
    await page.waitForFunction(() => !document.querySelector(".thread > .more"));
    const all60 = await ids(page);
    const asked = page.waitForRequest((request) => request.url().endsWith(`/rooms/${room}`), { timeout: 15000 });
    await page.evaluate(() => window.__sockets.forEach((one) => one.close()));
    await asked;
    await page.waitForTimeout(1500);
    const after60 = await ids(page);
    check("the catch-up keeps every message of a room whose ids are out of time order", after60.length === 60 && all60.every((v, i) => after60[i] === v), after60.length);
  } else {
    console.log("SKIP the room with ids out of time order (DATA_DIR is not set)");
  }

  await browser.close();
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });

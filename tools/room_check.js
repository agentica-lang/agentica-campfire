// The browser check of the room page script (`public/assets/campfire-DIGEST.js`): the local time of the messages, the
// pages that load when the reader scrolls (older above, newer below on a page at a cursor) and the reading position that
// stays where it is when the list changes. It is not part of `make test` or of CI, which have no browser: run it by hand
// after a change to the script.
//
//   CAMPFIRE_SESSION_SECRET=... CAMPFIRE_PORT=3592 CAMPFIRE_DATA_DIR=/tmp/room agentica campfire.agc
//   BASE=http://127.0.0.1:3592 CHROMIUM=/usr/bin/chromium PLAYWRIGHT_CORE=playwright-core node tools/room_check.js
//
// It needs a new database (it makes the first admin, "ana@example.com"), `playwright-core` and a Chromium, as
// `keys_check.js` does. It adds 130 messages to room 1 and exits 1 when a check fails.
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

  await browser.close();
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });

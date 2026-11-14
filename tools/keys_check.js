// The browser check of the keys of the composer and of the edit page (`public/assets/campfire-DIGEST.js`): Enter and
// Shift+Enter, Ctrl and Cmd+Enter, Reply, and Enter on a touch screen in a room, Ctrl+Enter and Esc on the page that edits a
// message. It is not part of `make test` or of CI, which have no browser: run it by hand after a change to the script.
//
//   CAMPFIRE_SESSION_SECRET=... CAMPFIRE_PORT=3591 CAMPFIRE_DATA_DIR=/tmp/keys agentica campfire.agc
//   BASE=http://127.0.0.1:3591 CHROMIUM=/usr/bin/chromium PLAYWRIGHT_CORE=playwright-core node tools/keys_check.js
//
// It needs a new database (it makes the first admin, "ana@example.com"), `playwright-core` (`npm install playwright-core`
// in a folder of your own, and point PLAYWRIGHT_CORE at it if it is not on the module path) and a Chromium (CHROMIUM,
// default /usr/bin/chromium). It adds a few messages to room 1 and exits 1 when a check fails.
const { chromium } = require(process.env.PLAYWRIGHT_CORE || "playwright-core");
const base = process.env.BASE || "http://127.0.0.1:3591";
let failed = 0;
function check(name, ok, extra) { console.log((ok ? "PASS " : "FAIL ") + name + (ok ? "" : " " + (extra || ""))); if (!ok) failed++; }

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || "/usr/bin/chromium", args: ["--no-sandbox"] });
  async function session(touch) {
    const ctx = await browser.newContext(touch ? { hasTouch: true, isMobile: true, viewport: { width: 390, height: 800 } } : {});
    return { page: await ctx.newPage() };
  }
  // First run, then sign in is automatic.
  let { page } = await session(false);
  await page.goto(base + "/");
  if (page.url().includes("first_run")) {
    await page.fill('input[name="name"]', "Ana");
    await page.fill('input[name="email"]', "ana@example.com");
    await page.fill('input[name="password"]', "correct horse battery");
    await Promise.all([page.waitForNavigation(), page.click('button[type="submit"]')]);
  } else if (page.url().includes("session/new")) {
    await page.fill('input[name="email_address"]', "ana@example.com");
    await page.fill('input[name="password"]', "correct horse battery");
    await Promise.all([page.waitForNavigation(), page.click('button[type="submit"]')]);
  }
  await page.goto(base + "/rooms/1");
  const box = page.locator('main.room textarea[name="message[body]"]');
  const count = () => page.locator("[data-message-id]").count();
  const start = await count();

  // Enter sends, and the box is cleared.
  await box.click();
  await box.type("first by enter");
  await page.keyboard.press("Enter");
  await page.waitForFunction((n) => document.querySelectorAll("[data-message-id]").length === n + 1, start);
  check("Enter sends", (await count()) === start + 1);
  check("Enter clears the box", (await box.inputValue()) === "");

  // Shift+Enter is a new line and sends nothing.
  await box.type("line one");
  await page.keyboard.press("Shift+Enter");
  await box.type("line two");
  check("Shift+Enter is a new line", (await box.inputValue()) === "line one\nline two");
  check("Shift+Enter sends nothing", (await count()) === start + 1);

  // Ctrl+Enter sends the two lines as one message.
  await page.keyboard.press("Control+Enter");
  await page.waitForFunction((n) => document.querySelectorAll("[data-message-id]").length === n + 2, start);
  check("Ctrl+Enter sends", (await count()) === start + 2);
  check("the two lines are one message", (await page.locator("[data-message-id]").last().innerText()).includes("line one"));

  // Enter on a blank box sends nothing and shows no validation bubble to dismiss.
  await box.fill("   ");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(400);
  check("Enter on a blank box sends nothing", (await count()) === start + 2);

  // Meta+Enter sends too.
  await box.fill("by meta");
  await page.keyboard.press("Meta+Enter");
  await page.waitForFunction((n) => document.querySelectorAll("[data-message-id]").length === n + 3, start);
  check("Cmd+Enter sends", (await count()) === start + 3);

  // The edit page: Ctrl+Enter saves, Esc goes back and discards.
  const id = await page.locator("[data-message-id]").last().getAttribute("data-message-id");
  await page.goto(base + `/rooms/1/messages/${id}/edit`);
  const edit = page.locator('turbo-frame form textarea[name="message[body]"]');
  await edit.fill("edited with the keyboard");
  await Promise.all([page.waitForNavigation(), page.keyboard.press("Control+Enter")]);
  await page.goto(base + "/rooms/1");
  check("Ctrl+Enter saves an edit", (await page.locator(`#presentation_message_${id}`).innerText()).includes("edited with the keyboard"));

  await page.goto(base + `/rooms/1/messages/${id}/edit`);
  await page.locator('turbo-frame form textarea').fill("should be discarded");
  await Promise.all([page.waitForNavigation(), page.keyboard.press("Escape")]);
  check("Esc goes back to the room", page.url() === base + "/rooms/1");
  check("Esc discards the change", (await page.locator(`#presentation_message_${id}`).innerText()).includes("edited with the keyboard"));

  // Ctrl+Enter with the focus on the Delete button saves nothing.
  await page.goto(base + `/rooms/1/messages/${id}/edit`);
  await page.locator('turbo-frame form textarea').fill("typed but not saved");
  await page.locator('button.danger').focus();
  await page.keyboard.press("Control+Enter");
  await page.waitForTimeout(400);
  check("Ctrl+Enter from the Delete button saves nothing", page.url().endsWith("/edit"));

  // Esc with the focus on the Delete button also leaves.
  await page.goto(base + `/rooms/1/messages/${id}/edit`);
  await page.locator('button.danger').focus();
  await Promise.all([page.waitForNavigation(), page.keyboard.press("Escape")]);
  check("Esc leaves from the Delete button", page.url() === base + "/rooms/1");

  // Reply puts a quote of the message and its author into the box; sent, it is a blockquote and a mention.
  await page.goto(base + "/rooms/1");
  await box.fill("first line");
  await page.keyboard.press("Shift+Enter");
  await box.type("second <b>line</b>");
  await page.keyboard.press("Control+Enter");
  const replied = start + 4;
  await page.waitForFunction((n) => document.querySelectorAll("[data-message-id]").length === n, replied);
  await page.locator("[data-message-id]").last().locator("button[data-reply]").click();
  check("Reply quotes the message", (await box.inputValue()) === "> first line\n> second <b>line</b>\n@Ana ", await box.inputValue());
  check("Reply focuses the box", await box.evaluate((el) => el === document.activeElement));
  await box.type("agreed");
  await page.keyboard.press("Enter");
  await page.waitForFunction((n) => document.querySelectorAll("[data-message-id]").length === n + 1, replied);
  const reply = page.locator("[data-message-id]").last();
  check("the reply shows a blockquote", (await reply.locator("blockquote").innerText()) === "first line\nsecond <b>line</b>");
  check("the reply mentions the author", (await reply.locator('action-text-attachment[gid="gid://campfire/User/1"]').count()) === 1);
  check("a reply to a reply drops the older quote", await reply.locator("button[data-reply]").click().then(() => box.inputValue()).then((v) => v === "> @Ana agreed\n@Ana "));
  check("every message, the sent ones too, has Reply", (await page.locator("[data-message-id] > h3 button[data-reply]").count()) === (await count()));
  await box.fill("");

  // A touch screen: Enter is a new line and sends nothing.
  const t = await session(true);
  await t.page.goto(base + "/session/new");
  await t.page.fill('input[name="email_address"]', "ana@example.com");
  await t.page.fill('input[name="password"]', "correct horse battery");
  await Promise.all([t.page.waitForNavigation(), t.page.click('button[type="submit"]')]);
  await t.page.goto(base + "/rooms/1");
  const tbox = t.page.locator('main.room textarea[name="message[body]"]');
  const before = await t.page.locator("[data-message-id]").count();
  await tbox.click();
  await tbox.type("touch");
  await t.page.keyboard.press("Enter");
  await tbox.type("more");
  check("on a touch screen Enter is a new line", (await tbox.inputValue()) === "touch\nmore");
  check("on a touch screen Enter sends nothing", (await t.page.locator("[data-message-id]").count()) === before);
  // Ctrl+Enter is a send on a touch screen with a keyboard.
  await t.page.keyboard.press("Control+Enter");
  await t.page.waitForFunction((n) => document.querySelectorAll("[data-message-id]").length === n + 1, before);
  check("on a touch screen Ctrl+Enter sends", (await t.page.locator("[data-message-id]").count()) === before + 1);

  await browser.close();
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });

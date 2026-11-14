/* Pages of a room by scrolling, as `message_paginator.js` of Rails Campfire does. The "Older messages" link above the
   list loads the 40 messages before the first one (`/rooms/ID/messages?before=ID`) when it comes near the top of the
   view, and on a page that does not end at the newest message the "Latest messages" link loads the 40 after the last one
   (`?after=ID`) when it comes near the bottom. Both links stay in the page as the fallback of a browser without the
   script, and are taken away here when the server has nothing more (a 204, or a page with nothing new in it). Where the
   reader is does not move: the scroll keeper (`scroll_keeper.js`) sees the list change.
   - An answer that is a redirect (a session that ended: `fetch` follows it to the sign-in page and calls it a success) is a
     refusal, and nothing of it is inserted.
   - A load that failed for lack of a connection, or with a 5xx or a 429 (which may say when to come back, `Retry-After`),
     is tried again 3 times with a growing pause. After that the pager is asleep until the browser says it is online or
     the reader scrolls with the link in reach; the link stays all the while.
   - When the "Latest messages" link has nothing more to load, the page is the latest one, and the live part is told
     (`LATEST_EVENT`) to fetch the room once, for what was created while the pager walked down. */
import { olderNotice, latestNotice, LATEST_EVENT, WINDOW_EVENT } from "./room_page.js";

// How far from the edge of the view a link starts its load, so the page is there before the reader reaches the end.
var REACH_PX = 300;
var REACH = REACH_PX + "px 0px";
// The pauses before the tries of a failed load: 2 s, 4 s and 8 s, or what the server asked for when that is longer (up to
// 30 s).
var RETRY_MS = 2000;
var TRIES = 3;
var LONGEST_WAIT_S = 30;
// How many messages from the edge are tried as the cursor, when the ones before were deleted.
var CURSORS = 8;

export function startMessagePager(page) {
  "use strict";

  if (!window.IntersectionObserver || !window.fetch) {
    return;
  }

  var list = page.list;
  var base = "/rooms/" + page.id + "/messages";
  var seen = new IntersectionObserver(visible, { root: page.scroller, rootMargin: REACH });
  var busy = { before: false, after: false };
  var failures = { before: 0, after: 0 };
  // The side whose tries ran out: nothing is asked for until `wake`.
  var asleep = { before: false, after: false };
  // Bumped when the list is made a new page, so a load that began before does not touch it.
  var generation = 0;

  // The paragraph (`.more`) with the link, for each direction; null when the page lacks it.
  function notice(side) {
    return side === "before" ? olderNotice(list) : latestNotice(list);
  }

  // Watching again tells the observer where the link is now: it says so at once when the link is in reach, which is
  // how a page that does not fill the view asks for the next one.
  function watch(side) {
    var one = notice(side);
    if (one) {
      seen.unobserve(one);
      seen.observe(one);
    }
  }

  // Nothing more in that direction: the link goes. Reaching the newest message makes the page the latest one, and the
  // live part is told, since what was created while the pager walked down was heard by nobody.
  function finish(side) {
    var one = notice(side);
    if (one) {
      seen.unobserve(one);
      one.remove();
    }
    if (side === "after") {
      document.dispatchEvent(new Event(LATEST_EVENT));
    }
  }

  function visible(entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        load(entry.target === olderNotice(list) ? "before" : "after");
      }
    });
  }

  // The messages of the list that the cursor can be, from the edge inwards: the first ones for `before`, the last ones
  // for `after`.
  function cursors(side) {
    var items = Array.prototype.slice.call(list.querySelectorAll("[data-message-id]"));
    var near = side === "before" ? items.slice(0, CURSORS) : items.slice(-CURSORS).reverse();
    return near
      .map(function (item) {
        return parseInt(item.getAttribute("data-message-id"), 10) || 0;
      })
      .filter(Boolean);
  }

  // What the answer is made of: a page of messages ("" for a 204), or a refusal. A redirect is checked first, as a
  // redirected answer is not the one that was asked for, whatever its status says.
  function read(response) {
    if (response.redirected) {
      throw refusal(false, 0);
    }
    if (response.status === 204) {
      return "";
    }
    if (!response.ok) {
      // A server that is busy or limiting may answer again; the other refusals will not change.
      var seconds = parseInt(response.headers.get("Retry-After"), 10);
      throw refusal(response.status >= 500 || response.status === 429, seconds > 0 ? Math.min(seconds, LONGEST_WAIT_S) * 1000 : 0);
    }
    return response.text();
  }

  function refusal(again, wait) {
    var error = new Error("refused");
    error.again = again;
    error.wait = wait;
    return error;
  }

  // Asks for the page at the first cursor. A 204 is not the end when the message that was the cursor may be gone (deleted
  // since the list got it): the room answers 204 for a message it does not have. So the next one inwards is asked; at the
  // real end it answers with the edge message that the list has already, which is no news and ends the walk.
  function ask(side, ids, n) {
    return fetch(base + "?" + side + "=" + ids[n], { credentials: "same-origin", headers: { Accept: "text/html" } })
      .then(read)
      .then(function (text) {
        return text === "" && n + 1 < ids.length ? ask(side, ids, n + 1) : text;
      });
  }

  function load(side) {
    var ids = cursors(side);
    if (busy[side] || !ids.length) {
      return;
    }

    busy[side] = true;
    var started = generation;
    ask(side, ids, 0)
      .then(function (text) {
        failures[side] = 0;
        if (started !== generation || !notice(side)) {
          return;
        }

        // A page with no message that the list lacks is the end, as a 204 is: asking again would ask the same.
        if (text && add(side, text)) {
          watch(side);
        } else {
          finish(side);
        }
      })
      .catch(function (error) {
        var one = notice(side);
        if (started !== generation || !one) {
          return;
        }

        seen.unobserve(one);
        // No connection (a TypeError of fetch) or a busy server: tried again a few times; the link stays either way.
        if (error.again === false) {
          return;
        }
        if (failures[side] < TRIES) {
          failures[side] += 1;
          setTimeout(function () {
            watch(side);
          }, Math.max(RETRY_MS * Math.pow(2, failures[side] - 1), error.wait || 0));
        } else {
          asleep[side] = true;
        }
      })
      .then(function () {
        busy[side] = false;
        if (started !== generation) {
          watch(side);
        }
      });
  }

  // Puts the messages of the page that the list lacks (only those: whatever else the answer holds is not the list's)
  // above or below it; true when there was one.
  function add(side, text) {
    var holder = document.createElement("template");
    holder.innerHTML = text;
    var fresh = document.createDocumentFragment();
    // A copy of the children: appending one to `fresh` takes it out of the live collection.
    Array.prototype.slice.call(holder.content.children).forEach(function (item) {
      if (item.hasAttribute("data-message-id") && item.id && !document.getElementById(item.id)) {
        fresh.append(item);
      }
    });
    if (!fresh.children.length) {
      return false;
    }

    if (side === "before") {
      list.prepend(fresh);
      // The link of the fallback now points before what the page holds.
      var link = olderNotice(list).querySelector("a");
      link.setAttribute("href", link.getAttribute("href").replace(/before=\d+/, "before=" + cursors("before")[0]));
    } else {
      list.append(fresh);
    }
    return true;
  }

  function wake(side) {
    if (asleep[side]) {
      asleep[side] = false;
      failures[side] = 0;
      watch(side);
    }
  }

  // Is the link of this side within reach of the view (the same distance as the observer's)?
  function near(side) {
    var one = notice(side);
    if (!one) {
      return false;
    }

    var box = one.getBoundingClientRect();
    var view = page.scroller.getBoundingClientRect();
    return side === "before" ? box.bottom > view.top - REACH_PX : box.top < view.bottom + REACH_PX;
  }

  // The list was made a new page: its link above is a new one, and what the old one did is forgotten.
  document.addEventListener(WINDOW_EVENT, function () {
    generation += 1;
    asleep.before = false;
    failures.before = 0;
    watch("before");
  });

  window.addEventListener("online", function () {
    wake("before");
    wake("after");
  });
  page.scroller.addEventListener(
    "scroll",
    function () {
      ["before", "after"].forEach(function (side) {
        if (asleep[side] && near(side)) {
          wake(side);
        }
      });
    },
    { passive: true },
  );

  watch("before");
  watch("after");
}

/* Pages of a room by scrolling, as `message_paginator.js` of Rails Campfire does. The "Older messages" link above the
   list loads the 40 messages before the first one (`/rooms/ID/messages?before=ID`) when it comes near the top of the
   view, and on a page that does not end at the newest message the "Latest messages" link loads the 40 after the last one
   (`?after=ID`) when it comes near the bottom. Both links stay in the page as the fallback of a browser without the
   script, and are taken away here when the server has nothing more (a 204, or a page with nothing new in it). Where the reader is does not move: the
   scroll keeper (`scroll_keeper.js`) sees the list change. */
import { olderNotice, latestNotice, LATEST_EVENT } from "./room_page.js";

// How far from the edge of the view a link starts its load, so the page is there before the reader reaches the end.
var REACH = "300px 0px";
// A load that failed for lack of a connection, or with a 5xx or 429, is tried again after 2 s, 4 s and 8 s; then the link
// is left for the reader to follow.
var RETRY_MS = 2000;
var TRIES = 3;

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

  // The message of the list that the cursor is: the first for `before`, the last for `after`.
  function cursor(side) {
    var items = list.querySelectorAll("[data-message-id]");
    var item = items[side === "before" ? 0 : items.length - 1];
    return item ? parseInt(item.getAttribute("data-message-id"), 10) || 0 : 0;
  }

  // What the answer made of: a page of messages ("" for a 204), or a refusal. A redirect is a refusal: a session that
  // ended is answered with the sign-in page, which `fetch` follows and calls a success.
  function read(response) {
    if (response.status === 204) {
      return "";
    }
    if (response.redirected || !response.ok) {
      var error = new Error("refused");
      // A server that is busy or limiting may answer again; the other refusals will not change.
      error.again = response.status >= 500 || response.status === 429;
      throw error;
    }
    return response.text();
  }

  function load(side) {
    var id = cursor(side);
    if (busy[side] || !id) {
      return;
    }

    busy[side] = true;
    fetch(base + "?" + side + "=" + id, { credentials: "same-origin", headers: { Accept: "text/html" } })
      .then(read)
      .then(function (text) {
        failures[side] = 0;
        if (!notice(side)) {
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
        if (!one) {
          return;
        }

        seen.unobserve(one);
        // No connection (a TypeError of fetch) or a busy server: tried again a few times; the link stays either way.
        if ((error.again === undefined || error.again) && failures[side] < TRIES) {
          failures[side] += 1;
          setTimeout(function () {
            watch(side);
          }, RETRY_MS * Math.pow(2, failures[side] - 1));
        }
      })
      .then(function () {
        busy[side] = false;
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
      link.setAttribute("href", link.getAttribute("href").replace(/before=\d+/, "before=" + cursor("before")));
    } else {
      list.append(fresh);
    }
    return true;
  }

  watch("before");
  watch("after");
}

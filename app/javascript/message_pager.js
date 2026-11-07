/* Pages of a room by scrolling, as `message_paginator.js` of Rails Campfire does. The "Older messages" link above the
   list loads the 40 messages before the first one (`/rooms/ID/messages?before=ID`) when it comes near the top of the
   view, and on a page that does not end at the newest message the "Latest messages" link loads the 40 after the last one
   (`?after=ID`) when it comes near the bottom. Both links stay in the page as the fallback of a browser without the
   script, and are taken away here when the server has nothing more (a 204). Where the reader is does not move: the
   scroll keeper (`scroll_keeper.js`) sees the list change. */
import { olderNotice, latestNotice } from "./room_page.js";

// How far from the edge of the view a link starts its load, so the page is there before the reader reaches the end.
var REACH = "300px 0px";
// The pause before a load that failed for lack of a connection is tried again.
var RETRY_MS = 5000;

export function startMessagePager(page) {
  "use strict";

  if (!window.IntersectionObserver || !window.fetch) {
    return;
  }

  var list = page.list;
  var base = "/rooms/" + page.id + "/messages";
  var seen = new IntersectionObserver(visible, { root: page.scroller, rootMargin: REACH });
  var busy = { before: false, after: false };

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

  function load(side) {
    var id = cursor(side);
    if (busy[side] || !id) {
      return;
    }

    busy[side] = true;
    var again = true;
    fetch(base + "?" + side + "=" + id, { credentials: "same-origin", headers: { Accept: "text/html" } })
      .then(function (response) {
        if (response.status === 204) {
          return "";
        }
        // The server refused (the room is gone, the session ended): no retry, the link stays for the reader to follow.
        // A fetch with no connection rejects before this, and is tried again after a pause.
        again = false;
        return response.ok ? response.text() : Promise.reject(new Error("no page"));
      })
      .then(function (text) {
        again = true;
        var one = notice(side);
        if (!one) {
          return;
        }
        if (!text) {
          seen.unobserve(one);
          one.remove();
          return;
        }

        add(side, text);
        watch(side);
      })
      .catch(function () {
        var one = notice(side);
        if (one) {
          seen.unobserve(one);
        }
        if (again) {
          setTimeout(function () {
            watch(side);
          }, RETRY_MS);
        }
      })
      .then(function () {
        busy[side] = false;
      });
  }

  function add(side, text) {
    var holder = document.createElement("template");
    holder.innerHTML = text;
    // A message that came live while the page was in flight is in the list already.
    Array.prototype.forEach.call(holder.content.querySelectorAll("[data-message-id]"), function (item) {
      if (item.id && document.getElementById(item.id)) {
        item.remove();
      }
    });
    if (side === "before") {
      list.prepend(holder.content);
      // The link of the fallback now points before what the page holds.
      var link = olderNotice(list).querySelector("a");
      link.setAttribute("href", link.getAttribute("href").replace(/before=\d+/, "before=" + cursor("before")));
    } else {
      list.append(holder.content);
    }
  }

  watch("before");
  watch("after");
}

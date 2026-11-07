/* Keeps the reading position of a room, as `scroll_manager.js` of Rails Campfire does, whatever changes the thread: older
   messages loaded above, a message that arrives, one that is edited or boosted, a "Latest messages" link that goes away.
   It remembers where one message of the view is (the anchor) and where the scroll is; when the thread changes it puts
   the anchor back where it was, and when the reader was at the newest message of the room it stays there.
   - The scroller is a column-reverse box: the newest end is the origin of `scrollTop` (0, negative above it), so
     the distance from the end is `-scrollTop`. The browser's own scroll anchoring is off for it (`overflow-anchor` in
     the stylesheet), so this is the only thing that moves the scroll.
   - "At the newest message" is within 100 px of it (Rails' threshold), and counts only on a page that ends at the newest
     message of the room: on a page of older messages, new ones below belong to the page too, and the reader's place
     is kept. */
import { atLatest } from "./room_page.js";

var NEAR_END = 100;

export function startScrollKeeper(page) {
  "use strict";

  if (!window.MutationObserver) {
    return;
  }

  var scroller = page.scroller;
  var list = page.list;
  var anchor = null;
  var anchorId = "";
  var offset = 0;
  var seenTop = 0;

  function top(element) {
    return element.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
  }

  // The first message whose bottom edge is below the top of the view, found by bisection (the list is in page order).
  function firstInView() {
    var edge = scroller.getBoundingClientRect().top;
    var low = 0;
    var high = list.children.length - 1;
    var found = null;
    while (low <= high) {
      var middle = (low + high) >> 1;
      var item = list.children[middle];
      if (item.getBoundingClientRect().bottom > edge) {
        found = item;
        high = middle - 1;
      } else {
        low = middle + 1;
      }
    }
    return found;
  }

  function remember() {
    seenTop = scroller.scrollTop;
    anchor = firstInView();
    anchorId = anchor ? anchor.id : "";
    offset = anchor ? top(anchor) : 0;
  }

  // A change of the list never moves `scrollTop` by itself (its origin is the newest end), so the distance from the end
  // is read as it is. The anchor was remembered at the last scroll event: when the scroll moved since (the event is not
  // delivered yet), the anchor is stale and the place is what the reader just chose, so it is left alone.
  function keep() {
    if (-scroller.scrollTop <= NEAR_END && atLatest(list)) {
      scroller.scrollTop = 0;
    } else if (scroller.scrollTop === seenTop) {
      // An edit replaces the element of a message: the same id in the list is the same place.
      var now = anchor && anchor.isConnected ? anchor : anchorId ? document.getElementById(anchorId) : null;
      var moved = now && list.contains(now) ? top(now) - offset : 0;
      if (moved) {
        // A positive `scrollTop` change moves the content up, which is where an anchor that went down has to come back.
        scroller.scrollTop += moved;
      }
    }
    remember();
  }

  scroller.addEventListener("scroll", remember, { passive: true });
  // The thread, not only the list: the links above and below it come and go, and move the view as a message does.
  new MutationObserver(keep).observe(list.parentNode, { childList: true, subtree: true });
  remember();
}

/* What the scripts of a room page share: the pieces of the page they work on, found once. The list is the element that
   holds the messages (`messages_rooms_open_ID`), the scroller is the box that scrolls it (a column-reverse box, so
   `scrollTop` is 0 at the newest message and negative above it). The "Older messages" link is the element before the
   list and the "Latest messages" link the one after it; the server writes the second only on a page that does not end at
   the newest message (`?before=`, `/rooms/ID/@MESSAGE`). Null on a page that is not a room. */
export function roomPage() {
  var main = document.querySelector("main.room");
  var scroller = main ? main.querySelector(".scroller") : null;
  var list = main ? main.querySelector('[id^="messages_rooms_"]') : null;
  var match = list ? /_(\d+)$/.exec(list.id) : null;
  if (!scroller || !list || !match) {
    return null;
  }

  return { scroller: scroller, list: list, id: parseInt(match[1], 10) };
}

/* True when the list ends at the newest message of the room: only then does a message that is sent or heard belong at
   the end of it. Reading the page each time, not once, since the pager takes the "Latest messages" link away when it
   reaches the end. */
export function atLatest(list) {
  return !list || !list.nextElementSibling;
}

/* The "Older messages" and "Latest messages" paragraphs of a page, or null. */
export function olderNotice(list) {
  var before = list.previousElementSibling;
  return before && before.classList.contains("more") ? before : null;
}

export function latestNotice(list) {
  var after = list.nextElementSibling;
  return after && after.classList.contains("more") ? after : null;
}

// Sent on `document` by the pager when a page at a cursor reaches the newest message, so the live part can catch up.
export var LATEST_EVENT = "campfire:latest";

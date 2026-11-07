/* The time of a message in the viewer's own zone and language, as `local_time_controller.js` of Rails Campfire does. The
   server writes every `<time datetime="ISO">` with its UTC clock ("14:05") as the text and the ISO instant as the title,
   so a page without this script is right too. With it, the text is the time of the viewer's clock, with the date when
   the day is not today, and the title is the whole date and time. */
var clock = null;
var stamp = null;

/* Writes the local time into `root` when it is a `<time datetime>` and into each one under it (idempotent: it reads the
   attribute only). A time with no valid instant keeps the text the server wrote. */
export function localize(root) {
  if (!clock) {
    return;
  }

  var items = Array.prototype.slice.call(root.querySelectorAll("time[datetime]"));
  if (root.matches && root.matches("time[datetime]")) {
    items.unshift(root);
  }

  var today = new Date().toDateString();
  items.forEach(function (item) {
    var date = new Date(item.getAttribute("datetime"));
    if (isNaN(date.getTime())) {
      return;
    }

    item.textContent = (date.toDateString() === today ? clock : stamp).format(date);
    item.title = stamp.format(date);
  });
}

/* Localizes the page, and every `<time>` that comes into `main` later (a message that is heard, sent or loaded). */
export function startLocalTime() {
  "use strict";

  if (!window.Intl || !Intl.DateTimeFormat) {
    return;
  }

  try {
    clock = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
    stamp = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
  } catch (e) {
    return;
  }

  localize(document);
  var main = document.querySelector("main");
  if (main && window.MutationObserver) {
    new MutationObserver(function (records) {
      records.forEach(function (record) {
        Array.prototype.forEach.call(record.addedNodes, function (node) {
          if (node.nodeType === 1) {
            localize(node);
          }
        });
      });
    }).observe(main, { childList: true, subtree: true });
  }
}

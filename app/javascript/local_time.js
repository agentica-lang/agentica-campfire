/* The time of a message in the viewer's own zone and language, as `local_time_controller.js` of Rails Campfire does. The
   server writes every `<time datetime="ISO">` with its UTC clock ("14:05") as the text and the ISO instant as the title,
   so a page without this script is right too. With it, the text is the time of the viewer's clock, with the date when
   the day is not today, and the title is the whole date and time. */
var clock = null;
var stamp = null;

/* Writes the local time into each `<time datetime>` under `root` (idempotent: it reads the attribute only). */
export function localize(root) {
  if (!clock) {
    return;
  }

  var items = root.querySelectorAll("time[datetime]");
  var today = new Date().toDateString();
  for (var i = 0; i < items.length; i++) {
    var date = new Date(items[i].getAttribute("datetime"));
    if (isNaN(date.getTime())) {
      continue;
    }

    items[i].textContent = (date.toDateString() === today ? clock : stamp).format(date);
    items[i].title = stamp.format(date);
  }
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

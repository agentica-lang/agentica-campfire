/* Reply, as `reply_controller.js` of Rails Campfire: a button on each message of a room puts a quote of it into the
   composer, with a mention of its author after it, in place of what was there. The composer is a text box, so the quote
   is lines that start with `> `, which the server stores as a blockquote; like Rails, the quote drops the quotes of the
   message, and its mentions are text. The button needs this script, so the script adds it. */
var BLOCKS = /^(P|DIV|LI|PRE|TR|H[1-6]|UL|OL|TABLE)$/;

export function startReply() {
  "use strict";

  var main = document.querySelector("main.room");
  var field = main ? main.querySelector(':scope > form textarea[name="message[body]"]') : null;
  if (!field || !window.MutationObserver) {
    return;
  }

  function addButtons(root) {
    Array.prototype.forEach.call(root.querySelectorAll("[data-message-id] > h3"), function (heading) {
      if (heading.querySelector("button[data-reply]")) {
        return;
      }
      var button = document.createElement("button");
      button.type = "button";
      button.setAttribute("data-reply", "");
      button.textContent = "Reply";
      heading.append(button);
    });
  }

  addButtons(main);
  new MutationObserver(function (records) {
    records.forEach(function (record) {
      Array.prototype.forEach.call(record.addedNodes, function (node) {
        if (node.nodeType === 1) {
          addButtons(node.parentNode || node);
        }
      });
    });
  }).observe(main, { childList: true, subtree: true });

  main.addEventListener("click", function (event) {
    var button = event.target.closest ? event.target.closest("button[data-reply]") : null;
    var message = button ? button.closest("[data-message-id]") : null;
    var body = message ? message.querySelector('[id^="presentation_message_"]') : null;
    var author = message ? message.querySelector("h3 > strong") : null;
    if (!body || !author) {
      return;
    }

    var quote = quoteOf(body);
    field.value = (quote ? quote + "\n" : "") + "@" + author.textContent.trim() + " ";
    field.dispatchEvent(new Event("input", { bubbles: true }));
    field.focus();
    field.setSelectionRange(field.value.length, field.value.length);
  });
}

// The text of the body without its quotes and its file, one `> ` line per line of it.
function quoteOf(body) {
  var copy = body.cloneNode(true);
  Array.prototype.forEach.call(copy.querySelectorAll("blockquote, .attachment, a[download]"), function (node) {
    node.remove();
  });

  // Blocks break lines, and two blocks in a row leave one blank line between them, not more.
  var lines = textOf(copy, false)
    .split("\n")
    .map(function (line) {
      return line.trim();
    })
    .filter(function (line, i, all) {
      return line || all[i - 1];
    });
  while (lines.length && !lines[0]) {
    lines.shift();
  }
  while (lines.length && !lines[lines.length - 1]) {
    lines.pop();
  }
  return lines
    .map(function (line) {
      return line ? "> " + line : ">";
    })
    .join("\n");
}

function textOf(node, pre) {
  if (node.nodeType === 3) {
    return pre ? node.nodeValue : node.nodeValue.replace(/\n/g, " ");
  }
  if (node.nodeName === "BR") {
    return "\n";
  }
  var text = Array.prototype.map
    .call(node.childNodes, function (child) {
      return textOf(child, pre || node.nodeName === "PRE");
    })
    .join("");
  return BLOCKS.test(node.nodeName) ? "\n" + text + "\n" : text;
}

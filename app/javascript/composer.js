/* The composer of a room, as an enhancement: the form works without this file (a post and a redirect). With it, a message
   is sent with fetch, the text box keeps its focus (so a phone keeps its keyboard open) and the page does not reload.
   The post asks for a Turbo Stream, which the app already answers with the message to append (`create_message`).
   The keys are those of Rails Campfire: Enter sends and Shift+Enter is a new line (not on a touch screen, where Enter is
   a new line), Ctrl or Cmd+Enter sends; on the page that edits a message, Ctrl or Cmd+Enter saves and Esc goes back to
   the room, discarding the change. */
export function startComposer() {
  "use strict";

  var STREAM = "text/vnd.turbo-stream.html";

  // The edit page has its own form, the one in the frame of the message; the room page has the composer.
  var edit = document.querySelector('main > turbo-frame[id^="edit_message_"] > form');
  if (edit) {
    editKeys(edit);
    return;
  }

  var form = document.querySelector("main.room > form");
  // The empty line above the form that is made to be filled: a screen reader announces text put into a live region
  // that was already in the page, and may skip one that arrives with its text.
  var line = document.querySelector("main.room > p[aria-live]");
  if (!form || !line || !window.fetch || !window.URLSearchParams || !window.FormData) {
    return;
  }

  var field = form.elements["message[body]"];
  var ident = form.elements["message[client_message_id]"];
  var button = form.querySelector("button");
  var scroller = document.querySelector(".scroller");
  var busy = false;

  // The text box is not autofocused by the markup: a phone would open its keyboard on every page load, and a send used
  // to reload the page. Only a device with a mouse or a trackpad gets the focus.
  if (window.matchMedia && matchMedia("(pointer: fine)").matches) {
    field.focus();
  }

  // Tapping Send would move the focus to the button and close the keyboard. pointerdown and mousedown both, since a
  // browser sends one or the other first; touchstart is left alone, because cancelling it also cancels the click.
  // The keyboard (Enter, Space) does not send either, so it still activates the button.
  ["pointerdown", "mousedown"].forEach(function (name) {
    button.addEventListener(name, function (event) {
      event.preventDefault();
    });
  });

  // A touch screen has no Shift key to ask for a new line, so there a plain Enter stays one and only Send sends. The
  // main pointer decides, not whether the device can be touched (a laptop with a touch screen is a keyboard first), and
  // it is read at the key, since a tablet changes it when a keyboard is attached. Ctrl or Cmd+Enter is a send anywhere.
  function touching() {
    return !!window.matchMedia && matchMedia("(pointer: coarse)").matches;
  }

  field.addEventListener("keydown", function (event) {
    // `isComposing` and 229 are an input method choosing a character with Enter, which is not a send.
    if (event.key !== "Enter" || event.isComposing || event.keyCode === 229) {
      return;
    }

    var chord = event.ctrlKey || event.metaKey;
    if (chord || (!event.shiftKey && !touching())) {
      event.preventDefault();
      // A blank box sends nothing, and the browser's own "fill out this field" bubble would only get in the way.
      if (field.value.trim()) {
        submitForm(form);
      }
    }
  });

  form.addEventListener("submit", function (event) {
    if (busy) {
      event.preventDefault();
      return;
    }

    // A page of older messages (`?before=`) is not the end of the room: the plain post goes to the latest page.
    if (location.search) {
      return;
    }

    event.preventDefault();
    if (field.value.trim()) {
      send();
    } else {
      field.value = "";
    }
  });

  // `requestSubmit` runs the `submit` event as a click on Send does; an old browser without it clicks the button.
  function submitForm(target) {
    if (target.requestSubmit) {
      target.requestSubmit();
    } else {
      target.querySelector("button").click();
    }
  }

  function send() {
    var text = field.value;
    busy = true;
    button.disabled = true;
    fetch(form.action, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        Accept: STREAM,
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
      },
      body: new URLSearchParams(new FormData(form)),
    })
      .then(
        function (response) {
          // A refusal (too long, not allowed) is shown by the page that the plain post answers.
          if (!response.ok) {
            return form.submit();
          }
          return response.text().then(function (answer) {
            if (append(answer)) {
              sent(text);
            } else {
              form.submit();
            }
          });
        },
        function () {
          note("Not sent. Check the connection and try again.");
        },
      )
      // The answer came but could not be read: the message is stored, so the room page is loaded (a GET: the page may be
      // the answer of a refused post, which a reload would send again) to show it.
      .catch(function () {
        location.assign(form.action.replace(/\/messages$/, ""));
      })
      .then(function () {
        busy = false;
        button.disabled = false;
      });
  }

  // Puts the messages of each `append` of the stream into its target; false when the answer is not one we can read.
  function append(text) {
    var holder = document.createElement("template");
    holder.innerHTML = text;
    var streams = holder.content.querySelectorAll('turbo-stream[action="append"]');
    if (!streams.length) {
      return false;
    }

    var parts = [];
    for (var i = 0; i < streams.length; i++) {
      var target = document.getElementById(streams[i].getAttribute("target"));
      var items = streams[i].querySelector("template");
      if (!target || !items) {
        return false;
      }
      parts.push([target, items.content]);
    }

    parts.forEach(function (part) {
      // The broadcast of the same message may have come first, without the controls that this answer has: this copy
      // replaces it, and is at the end, where the newest message goes.
      Array.prototype.forEach.call(part[1].querySelectorAll("[id]"), function (item) {
        var old = document.getElementById(item.id);
        if (old) {
          old.remove();
        }
      });
      part[0].append(part[1]);
    });
    return true;
  }

  // `text` is what was sent: what the person typed since stays in the box.
  function sent(text) {
    var empty = document.querySelector(".thread .empty");
    if (empty) {
      empty.remove();
    }
    note("");
    if (field.value === text) {
      field.value = "";
    }
    ident.value = freshId();
    // The list is a column-reverse box: 0 is its end, where the new message is.
    scroller.scrollTop = 0;
    field.focus({ preventScroll: true });
  }

  function freshId() {
    if (!window.crypto || !crypto.getRandomValues) {
      return "";
    }
    var bytes = crypto.getRandomValues(new Uint8Array(16));
    return Array.prototype.map
      .call(bytes, function (b) {
        return (b < 16 ? "0" : "") + b.toString(16);
      })
      .join("");
  }

  // The line above the form that says why a message was not sent; "" empties it.
  function note(text) {
    var server = document.querySelector('main.room > [role="alert"]');
    if (server) {
      server.remove();
    }
    line.textContent = text;
  }

  // The page of a message that is being edited: Ctrl or Cmd+Enter saves it, as the button does, and Esc leaves for the
  // room with the change discarded (the link under the form, which is also what a person without the script clicks).
  function editKeys(target) {
    var back = document.querySelector("main > p > a[data-cancel]");
    var saving = false;

    // One save at a time: the page is about to be replaced by the answer, and a second post would save it twice.
    target.addEventListener("submit", function (event) {
      if (saving) {
        event.preventDefault();
      }
      saving = true;
    });

    // The frame, not the form, so Esc also works with the focus on the Delete button.
    target.parentNode.addEventListener("keydown", function (event) {
      if (event.isComposing || event.keyCode === 229) {
        return;
      }

      // Only with the focus in the save form: from the Delete button a chord must not save what was typed.
      if (event.key === "Enter" && (event.ctrlKey || event.metaKey) && target.contains(event.target)) {
        event.preventDefault();
        if (!saving) {
          submitForm(target);
        }
      } else if (event.key === "Escape" && back) {
        event.preventDefault();
        location.assign(back.href);
      }
    });
  }
}

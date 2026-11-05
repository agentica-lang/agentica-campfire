/* The composer of a room, as an enhancement: the form works without this file (a post and a redirect). With it, a message
   is sent with fetch, the text box keeps its focus (so a phone keeps its keyboard open) and the page does not reload.
   The post asks for a Turbo Stream, which the app already answers with the message to append (`create_message`). */
(function () {
  "use strict";

  var STREAM = "text/vnd.turbo-stream.html";
  var form = document.querySelector("main.room > form");
  if (!form || !window.fetch || !window.URLSearchParams || !window.FormData) {
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

  // Tapping Send would move the focus to the button and close the keyboard.
  button.addEventListener("pointerdown", function (event) {
    event.preventDefault();
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

  function send() {
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
          return response.text().then(function (text) {
            if (append(text)) {
              sent();
            } else {
              form.submit();
            }
          });
        },
        function () {
          note("Not sent. Check the connection and try again.");
        },
      )
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
      part[0].append(part[1]);
    });
    return true;
  }

  function sent() {
    var empty = document.querySelector(".thread .empty");
    if (empty) {
      empty.remove();
    }
    note("");
    field.value = "";
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

  // The line above the form that says why a message was not sent; "" takes it away.
  function note(text) {
    var alert = form.previousElementSibling;
    if (!alert || alert.getAttribute("role") !== "alert") {
      if (!text) {
        return;
      }
      alert = document.createElement("p");
      alert.setAttribute("role", "alert");
      form.parentNode.insertBefore(alert, form);
    }

    if (text) {
      alert.textContent = text;
    } else {
      alert.remove();
    }
  }
})();

/* The script of the pages, two parts that need nothing of each other. The composer of a room (first) and the live updates
   (second, in every page with the sidebar) are enhancements: the pages work without this file.

   The composer of a room, as an enhancement: the form works without this file (a post and a redirect). With it, a message
   is sent with fetch, the text box keeps its focus (so a phone keeps its keyboard open) and the page does not reload.
   The post asks for a Turbo Stream, which the app already answers with the message to append (`create_message`). */
(function () {
  "use strict";

  var STREAM = "text/vnd.turbo-stream.html";
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
})();

/* The live part: one WebSocket to `/cable` (Action Cable, `actioncable-v1-json`), opened by every page with the sidebar.
   What it hears is a Turbo Stream, which it applies itself (append, prepend, replace, update, remove, before, after;
   no Turbo library), or a notice that a room has something new.
   - The signed names of the sidebar streams come from `GET /users/me/sidebar`, not from the page: a room page is kept
     whole for each person, and its markup is the benchmark's.
   - On a room page it also listens to the stream of the room, and tells the server that a tab is looking at it
     (`PresenceChannel`), which reads the room.
   - Every page asks the server to check its session every 50 s (`HeartbeatChannel` `check`), so a socket does not
     outlive a sign-out. */
(function () {
  "use strict";

  var nav = document.querySelector('nav[aria-label="Rooms"]');
  if (!nav || !window.WebSocket || !window.fetch || !window.DOMParser) {
    return;
  }

  var BEAT_MS = 50000;
  // The server pings every 3 s: a socket that heard nothing for this long is dead, whatever the browser says.
  var STALE_MS = 12000;
  var SIDEBAR = "/users/me/sidebar";

  var main = document.querySelector("main.room");
  var list = main ? main.querySelector('[id^="messages_rooms_"]') : null;
  var match = list ? /_(\d+)$/.exec(list.id) : null;
  var roomId = match ? parseInt(match[1], 10) : null;
  // A page of older messages (`?before=`) is not the end of the room: the newest message does not belong in it.
  var latest = !location.search;

  var subscriptions = [];
  var socket = null;
  var welcomed = false;
  var everWelcomed = false;
  var stopped = false;
  var attempts = 0;
  var lastPing = 0;
  var presence = null;
  var heartbeat = null;

  function visible() {
    return document.visibilityState !== "hidden";
  }

  function identify(parts) {
    return JSON.stringify(parts);
  }

  // `handle` gets what the channel sends (a string for a Turbo Stream, an object for a notice).
  function subscribe(parts, handle) {
    var one = { id: identify(parts), handle: handle, rejected: false };
    subscriptions.push(one);
    if (welcomed) {
      send({ command: "subscribe", identifier: one.id });
    }
    return one.id;
  }

  function send(frame) {
    if (socket && socket.readyState === 1) {
      socket.send(JSON.stringify(frame));
    }
  }

  function perform(id, action) {
    send({ command: "message", identifier: id, data: JSON.stringify({ action: action }) });
  }

  function connect() {
    if (stopped) {
      return;
    }

    var ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/cable", "actioncable-v1-json");
    socket = ws;
    ws.onmessage = function (event) {
      if (ws === socket) {
        receive(event.data);
      }
    };
    ws.onclose = function () {
      if (ws === socket) {
        lost();
      }
    };
  }

  // Tries again after a pause that doubles up to 30 s, with jitter so that the tabs of a restarted server do not come
  // back in one burst. A `disconnect` that says not to come back (`stopped`) ends it.
  function lost() {
    welcomed = false;
    socket = null;
    if (stopped) {
      return;
    }

    attempts += 1;
    var wait = Math.min(30000, 1000 * Math.pow(2, attempts - 1));
    setTimeout(connect, wait * (0.5 + Math.random() / 2));
  }

  function receive(text) {
    var frame;
    try {
      frame = JSON.parse(text);
    } catch (e) {
      return;
    }

    switch (frame.type) {
      case "welcome":
        welcomed = true;
        attempts = 0;
        lastPing = Date.now();
        subscriptions.forEach(function (one) {
          one.rejected = false;
          send({ command: "subscribe", identifier: one.id });
        });
        if (everWelcomed) {
          catchUp();
        }
        everWelcomed = true;
        return;
      case "ping":
        lastPing = Date.now();
        return;
      case "disconnect":
        if (frame.reconnect === false) {
          stopped = true;
        }
        return;
      case "confirm_subscription":
        if (frame.identifier === presence && !visible()) {
          perform(presence, "absent");
        }
        return;
      case "reject_subscription":
        subscriptions.forEach(function (one) {
          if (one.id === frame.identifier) {
            one.rejected = true;
          }
        });
        return;
    }

    if (frame.identifier && frame.message !== undefined) {
      subscriptions.forEach(function (one) {
        if (one.id === frame.identifier && one.handle) {
          one.handle(frame.message);
        }
      });
    }
  }

  setInterval(function () {
    if (socket && welcomed && Date.now() - lastPing > STALE_MS) {
      var dead = socket;
      socket = null;
      try {
        dead.close();
      } catch (e) {
        // already closed
      }
      lost();
    }
  }, 3000);

  setInterval(function () {
    if (!welcomed) {
      return;
    }

    perform(heartbeat, "check");
    if (presence && visible()) {
      perform(presence, "refresh");
    }
  }, BEAT_MS);

  // Turbo Streams. An element that is in the page already is not added twice (the sender's own tab has it from the
  // answer of its post).
  function apply(html) {
    var holder = document.createElement("template");
    holder.innerHTML = html;
    var streams = holder.content.querySelectorAll("turbo-stream");
    for (var i = 0; i < streams.length; i++) {
      step(streams[i]);
    }
  }

  function step(stream) {
    var action = stream.getAttribute("action");
    var name = stream.getAttribute("target") || "";
    var target = document.getElementById(name);
    var template = stream.querySelector("template");
    var content = template ? template.content : document.createDocumentFragment();
    if (!target && action === "append" && name === "direct_rooms") {
      target = directList();
    }
    if (!target) {
      return;
    }

    switch (action) {
      case "append":
      case "prepend":
        fresh(content);
        if (action === "append") {
          target.append(content);
        } else {
          target.prepend(content);
        }
        if (list && target === list) {
          var empty = document.querySelector(".thread .empty");
          if (empty) {
            empty.remove();
          }
        }
        break;
      case "replace":
        replace(target, content);
        break;
      case "update":
        target.replaceChildren(content);
        break;
      case "remove":
        target.remove();
        break;
      case "before":
        target.before(content);
        break;
      case "after":
        target.after(content);
        break;
    }
  }

  // Drops from `content` what the page has by id.
  function fresh(content) {
    Array.prototype.forEach.call(content.querySelectorAll("[id]"), function (item) {
      if (document.getElementById(item.id)) {
        item.remove();
      }
    });
  }

  // A renamed room keeps its unread mark.
  function replace(target, content) {
    var unread = target.classList.contains("unread");
    var id = target.id;
    target.replaceWith(content);
    var now = document.getElementById(id);
    if (unread && now) {
      mark(now);
    }
  }

  // The first direct message: the list is not in the sidebar until there is one.
  function directList() {
    var lists = nav.querySelector(".lists");
    var actions = nav.querySelector(".actions");
    if (!lists || !actions) {
      return null;
    }

    var heading = document.createElement("h2");
    heading.textContent = "Direct messages";
    var direct = document.createElement("ul");
    direct.id = "direct_rooms";
    lists.insertBefore(heading, actions);
    lists.insertBefore(direct, actions);
    return direct;
  }

  // The unread mark of a room in the sidebar: a class for the style and a word for a screen reader.
  function mark(item) {
    if (item.classList.contains("unread")) {
      return;
    }

    item.classList.add("unread");
    var link = item.querySelector("a");
    if (link) {
      var word = document.createElement("span");
      word.className = "sr-only";
      word.textContent = " (unread)";
      link.append(word);
    }
  }

  function unmark(id) {
    var item = document.getElementById("room_" + id);
    if (!item || !item.classList.contains("unread")) {
      return;
    }

    item.classList.remove("unread");
    var word = item.querySelector("a .sr-only");
    if (word) {
      word.remove();
    }
  }

  // `{"roomId":ID,"at":TIME}`. The room that this tab shows is read as it comes, unless the tab is hidden.
  function unread(notice) {
    if (!notice || typeof notice.roomId !== "number") {
      return;
    }
    if (notice.roomId === roomId && visible()) {
      return;
    }

    var item = document.getElementById("room_" + notice.roomId);
    if (item) {
      mark(item);
    }
  }

  // After a reconnect the messages that came while the socket was away are fetched with the page and added; what the
  // page has already is left alone.
  function catchUp() {
    if (!list || !latest || !roomId) {
      return;
    }

    fetch(location.href, { credentials: "same-origin", headers: { Accept: "text/html" } })
      .then(function (response) {
        return response.ok ? response.text() : "";
      })
      .then(function (text) {
        var theirs = text ? new DOMParser().parseFromString(text, "text/html").getElementById(list.id) : null;
        if (!theirs || !document.getElementById(list.id)) {
          return;
        }

        Array.prototype.forEach.call(theirs.children, function (item) {
          if (item.id && !document.getElementById(item.id)) {
            list.append(document.importNode(item, true));
          }
        });
      })
      .catch(function () {
        // the next reconnect tries again
      });
  }

  function room(html) {
    if (typeof html !== "string" || !latest) {
      return;
    }

    apply(html);
    // The room was deleted: the stream replaced the page with a notice, so there is nobody to tell any more.
    if (!document.querySelector("main.room")) {
      roomId = null;
      presence = null;
    }
  }

  function sidebarSources() {
    fetch(SIDEBAR, { credentials: "same-origin" })
      .then(function (response) {
        return response.ok ? response.text() : Promise.reject(new Error("no sidebar"));
      })
      .then(function (text) {
        var sources = new DOMParser().parseFromString(text, "text/html").querySelectorAll("turbo-cable-stream-source");
        Array.prototype.forEach.call(sources, function (source) {
          subscribe(
            { channel: source.getAttribute("channel"), signed_stream_name: source.getAttribute("signed-stream-name") },
            function (html) {
              if (typeof html === "string") {
                apply(html);
              }
            },
          );
        });
      })
      .catch(function () {
        setTimeout(sidebarSources, 5000);
      });
  }

  heartbeat = subscribe({ channel: "HeartbeatChannel" }, null);
  subscribe({ channel: "UnreadRoomsChannel" }, unread);
  if (main) {
    Array.prototype.forEach.call(main.querySelectorAll("turbo-cable-stream-source"), function (source) {
      subscribe(
        { channel: source.getAttribute("channel"), signed_stream_name: source.getAttribute("signed-stream-name") },
        room,
      );
    });
  }
  if (roomId) {
    presence = subscribe({ channel: "PresenceChannel", room_id: roomId }, null);
    document.addEventListener("visibilitychange", function () {
      if (!presence) {
        return;
      }
      if (visible()) {
        perform(presence, "present");
        unmark(roomId);
      } else {
        perform(presence, "absent");
      }
    });
  }
  sidebarSources();
  connect();
})();

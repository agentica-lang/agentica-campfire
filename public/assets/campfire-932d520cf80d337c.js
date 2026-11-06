/* The script of the pages, two parts that need nothing of each other. The composer of a room (first) and the live updates
   (second, in every page with the sidebar) are enhancements: the pages work without this file.

/* The composer of a room, as an enhancement: the form works without this file (a post and a redirect). With it, a message
   is sent with fetch, the text box keeps its focus (so a phone keeps its keyboard open) and the page does not reload.
   The post asks for a Turbo Stream, which the app already answers with the message to append (`create_message`).
   The keys are those of Rails Campfire: Enter sends and Shift+Enter is a new line (not on a touch screen, where Enter is
   a new line), Ctrl or Cmd+Enter sends; on the page that edits a message, Ctrl or Cmd+Enter saves and Esc goes back to
   the room, discarding the change. */
(function () {
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
  var roomSub = null;
  var unreadSub = null;
  // After a reconnect, what the page lacks is fetched once the subscription that would have brought it is confirmed:
  // what comes after the confirmation arrives live, and what came before is in the fetch (a message in both is added
  // once).
  var catchRoom = false;
  var catchSidebar = false;
  var sidebarTries = 0;

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

  // The pause before try number `n`: it doubles up to 30 s, with jitter so that the tabs of a restarted server do not
  // come back in one burst.
  function pause(n) {
    return Math.min(30000, 1000 * Math.pow(2, n - 1)) * (0.5 + Math.random() / 2);
  }

  // Tries again after a pause. A `disconnect` that says not to come back (`stopped`) ends it.
  function lost() {
    welcomed = false;
    socket = null;
    if (stopped) {
      return;
    }

    attempts += 1;
    setTimeout(connect, pause(attempts));
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
        catchRoom = everWelcomed && roomSub !== null && latest;
        catchSidebar = everWelcomed;
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
        if (frame.identifier === roomSub && catchRoom) {
          catchRoom = false;
          catchUp();
        }
        if (frame.identifier === unreadSub && catchSidebar) {
          catchSidebar = false;
          loadSidebar(true);
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
        if (target.id === "shared_rooms" || target.id === "direct_rooms") {
          insertRooms(target, content);
        } else if (action === "append") {
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

  // A room goes where the server's order puts it: by name without the case of ASCII letters (SQLite's `lower`), then
  // by id.
  function sortKey(item) {
    var link = item.querySelector("a");
    var name = link && link.firstChild ? link.firstChild.textContent : "";
    return {
      name: name.replace(/[A-Z]/g, function (c) {
        return c.toLowerCase();
      }),
      id: parseInt(item.id.replace("room_", ""), 10) || 0,
    };
  }

  function before(one, other) {
    return one.name < other.name || (one.name === other.name && one.id < other.id);
  }

  function insertRooms(target, content) {
    Array.prototype.slice.call(content.children).forEach(function (item) {
      var key = sortKey(item);
      var next = null;
      Array.prototype.some.call(target.children, function (other) {
        if (before(key, sortKey(other))) {
          next = other;
          return true;
        }
        return false;
      });
      target.insertBefore(item, next);
    });
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

  // After a reconnect the room page is fetched and its list of messages is made the list of the page: a message that was
  // deleted while the socket was away goes, an edited one is replaced, and the ones that came are added, in the
  // server's order. A message newer than the fetched ones (the answer of a post that is still going, or one that came
  // live after the fetch was made) and one older than they are (the page shows the newest 40) are left alone. The
  // composer is not touched.
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
        if (theirs && document.getElementById(list.id) === list) {
          reconcile(theirs);
        }
      })
      .catch(function () {
        // the next reconnect tries again
      });
  }

  function numberOf(item) {
    return parseInt(item.getAttribute("data-message-id"), 10) || 0;
  }

  function reconcile(theirs) {
    var wanted = {};
    var low = Infinity;
    var high = 0;
    Array.prototype.forEach.call(theirs.children, function (item) {
      wanted[item.id] = true;
      low = Math.min(low, numberOf(item));
      high = Math.max(high, numberOf(item));
    });

    Array.prototype.slice.call(list.children).forEach(function (item) {
      var n = numberOf(item);
      if (item.id && !wanted[item.id] && n >= low && n <= high) {
        item.remove();
      }
    });

    var previous = null;
    Array.prototype.forEach.call(theirs.children, function (item) {
      var copy = document.importNode(item, true);
      var mine = document.getElementById(item.id);
      if (mine && mine.parentNode === list) {
        if (mine.outerHTML !== copy.outerHTML) {
          mine.replaceWith(copy);
          mine = copy;
        }
      } else if (previous) {
        previous.after(copy);
        mine = copy;
      } else {
        list.prepend(copy);
        mine = copy;
      }
      previous = mine;
    });

    var empty = document.querySelector(".thread .empty");
    if (empty && list.children.length) {
      empty.remove();
    }
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

  // The sidebar page gives the signed names of the sidebar streams (the first time) and, after a reconnect, the rooms and
  // the unread marks as they are now. A failed try is repeated after a longer pause each time, up to 8 tries.
  function loadSidebar(again) {
    fetch(SIDEBAR, { credentials: "same-origin" })
      .then(function (response) {
        return response.ok ? response.text() : Promise.reject(new Error("no sidebar"));
      })
      .then(function (text) {
        sidebarTries = 0;
        var doc = new DOMParser().parseFromString(text, "text/html");
        if (again) {
          reconcileSidebar(doc);
          return;
        }

        Array.prototype.forEach.call(doc.querySelectorAll("turbo-cable-stream-source"), function (source) {
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
        sidebarTries += 1;
        if (!stopped && sidebarTries < 8) {
          setTimeout(function () {
            loadSidebar(again);
          }, pause(sidebarTries));
        }
      });
  }

  function reconcileSidebar(doc) {
    var theirs = doc.querySelector(".lists");
    var mine = nav.querySelector(".lists");
    if (!theirs || !mine) {
      return;
    }

    mine.innerHTML = theirs.innerHTML;
    // The room that a visible tab shows is read, whatever the page of the sidebar said before the presence came.
    if (roomId && visible()) {
      unmark(roomId);
    }
  }

  heartbeat = subscribe({ channel: "HeartbeatChannel" }, null);
  unreadSub = subscribe({ channel: "UnreadRoomsChannel" }, unread);
  if (main) {
    Array.prototype.forEach.call(main.querySelectorAll("turbo-cable-stream-source"), function (source) {
      roomSub = subscribe(
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
  loadSidebar(false);
  connect();
})();

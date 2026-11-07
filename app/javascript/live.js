import { localize } from "./local_time.js";
import { atLatest, LATEST_EVENT } from "./room_page.js";

/* The live part: one WebSocket to `/cable` (Action Cable, `actioncable-v1-json`), opened by every page with the sidebar.
   What it hears is a Turbo Stream, which it applies itself (append, prepend, replace, update, remove, before, after;
   no Turbo library), or a notice that a room has something new.
   - The signed names of the sidebar streams come from `GET /users/me/sidebar`, not from the page: a room page is kept
     whole for each person, and its markup is the benchmark's.
   - On a room page it also listens to the stream of the room, and tells the server that a tab is looking at it
     (`PresenceChannel`), which reads the room.
   - Every page asks the server to check its session every 50 s (`HeartbeatChannel` `check`), so a socket does not
     outlive a sign-out. */
export function startLive() {
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
  // A page of older messages (`?before=`, `/rooms/ID/@MESSAGE`) is not the end of the room: the newest message does not
  // belong in it, until the pager has reached the end.
  function latest() {
    return atLatest(list);
  }

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
  var sidebarStreams = false;
  // The catch-up in flight, if any: `seen` is the ids of the messages the page had when it started, and `touched` the
  // ids that a live event (a stream) named since, which the fetched page may predate.
  var catching = null;

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
        catchRoom = everWelcomed && roomSub !== null && latest();
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
    if (catching) {
      touch(name, content);
    }
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
        if (list && latest() && list.isConnected) {
          syncEmpty();
        }
        break;
      case "before":
        target.before(content);
        break;
      case "after":
        target.after(content);
        break;
    }
  }

  // Notes that a live event named this id, and the ones it brings, so that the catch-up leaves them as the event made
  // them.
  function touch(name, content) {
    catching.touched[name] = true;
    Array.prototype.forEach.call(content.querySelectorAll("[id]"), function (item) {
      catching.touched[item.id] = true;
    });
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

  // After a reconnect the room page is fetched and its list of messages is made the list of the page. Of the messages
  // that the page had when the catch-up began, the ones the fetched page lacks are gone (deleted while the socket was
  // away, the newest one included, or all of them when the room was emptied) unless they are older than the fetched
  // ones (the page shows the newest 40); an edited one is replaced and the ones that came are added, in the server's
  // order. What arrived live since the catch-up began (a message that is not in the first list, or one that a stream
  // touched) stays as the stream made it, as the fetch may be older than the stream. The composer is not touched.
  function catchUp() {
    if (!list || !latest() || !roomId) {
      return;
    }

    var mine = { seen: {}, touched: {} };
    Array.prototype.forEach.call(list.children, function (item) {
      if (item.id) {
        mine.seen[item.id] = true;
      }
    });
    catching = mine;

    // The room's own page, not `location.href`: a page at a cursor that the pager has taken to the end is the latest page
    // now, and its address is still the window of the cursor, which lacks the messages after it.
    fetch("/rooms/" + roomId, { credentials: "same-origin", headers: { Accept: "text/html" } })
      .then(function (response) {
        return response.ok && !response.redirected ? response.text() : "";
      })
      .then(function (text) {
        var theirs = text ? new DOMParser().parseFromString(text, "text/html").getElementById(list.id) : null;
        if (theirs && catching === mine && document.getElementById(list.id) === list) {
          reconcile(theirs, mine);
        }
      })
      .catch(function () {
        // the next reconnect tries again
      })
      .then(function () {
        if (catching === mine) {
          catching = null;
        }
      });
  }

  function reconcile(theirs, mine) {
    var wanted = {};
    var boundary = null;
    Array.prototype.forEach.call(theirs.children, function (item) {
      wanted[item.id] = true;
      var here = document.getElementById(item.id);
      if (!boundary && here && here.parentNode === list) {
        boundary = here;
      }
    });

    // What the fetch covers is told by position, not by id: the page is in the server's order (time, then id), and in a
    // database that Rails seeded an id does not follow time. With no fetched message every message of the first list is
    // gone; otherwise only the ones from the oldest fetched one that the list has on (the ones before it are on pages that
    // the fetch did not cover, the older messages that the pager loaded).
    var empty = theirs.children.length === 0;
    Array.prototype.slice.call(list.children).forEach(function (item) {
      var covered = empty || (boundary && (item === boundary || boundary.compareDocumentPosition(item) & Node.DOCUMENT_POSITION_FOLLOWING));
      if (item.id && mine.seen[item.id] && !wanted[item.id] && !mine.touched[item.id] && covered) {
        item.remove();
      }
    });

    var previous = null;
    Array.prototype.forEach.call(theirs.children, function (item) {
      if (mine.touched[item.id]) {
        previous = document.getElementById(item.id) || previous;
        return;
      }

      var copy = document.importNode(item, true);
      // The page in the list has its times in the viewer's zone, so the copy is compared in it too.
      localize(copy);
      var here = document.getElementById(item.id);
      if (here && here.parentNode === list) {
        if (here.outerHTML !== copy.outerHTML) {
          here.replaceWith(copy);
          here = copy;
        }
      } else if (previous) {
        previous.after(copy);
        here = copy;
      } else {
        list.prepend(copy);
        here = copy;
      }
      previous = here;
    });

    syncEmpty();
  }

  // The notice of a room with no message is in the page when it was made empty and is not when it was not, so the
  // script adds and removes it as the list fills and empties.
  function syncEmpty() {
    var empty = document.querySelector(".thread .empty");
    if (list.children.length) {
      if (empty) {
        empty.remove();
      }
    } else if (!empty) {
      var notice = document.createElement("p");
      notice.className = "empty";
      notice.textContent = "No messages here yet.";
      list.parentNode.insertBefore(notice, list);
    }
  }

  function room(html) {
    if (typeof html !== "string" || !latest()) {
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
        }

        // A reload after a reconnect subscribes too when the first load gave up; the flag keeps two loads in flight from
        // subscribing twice.
        if (sidebarStreams) {
          return;
        }

        sidebarStreams = true;
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

    // A live unread mark that arrives between the fetch and this line is lost with the old lists (the next notice or
    // reload brings it back); the window is the time of one request.
    mine.innerHTML = theirs.innerHTML;
    // The room that a visible tab shows is read, whatever the page of the sidebar said before the presence came.
    if (roomId && visible()) {
      unmark(roomId);
    }
  }

  // The pager reached the end of a page at a cursor: what was created while it walked down is fetched once.
  document.addEventListener(LATEST_EVENT, catchUp);

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
}

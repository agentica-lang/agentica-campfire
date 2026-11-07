/* Boosts under a message, as an enhancement: the link "Boost" and the forms work without this file (the page that
   adds a boost, a post and a redirect). With it, the link opens the reactions and the words under the message, a post
   goes with fetch asking for a Turbo Stream, and the room page does not reload. What the stream says is applied here
   (append the boost, remove it); the same boost may have come already over /cable (live.js), and then it is kept
   once. */
export function startBoosts() {
  "use strict";

  if (!window.fetch || !window.DOMParser || !window.URLSearchParams || !window.FormData) {
    return;
  }

  var STREAM = "text/vnd.turbo-stream.html";
  var AREA = '[id^="boosts_message_"]';
  var busy = false;
  // The next submit is the browser's own: the answer of a fetch was not usable, so the form is sent as it is.
  var plain = false;

  function areaOf(node) {
    return node.closest ? node.closest(AREA) : null;
  }

  function menuOf(area) {
    return area.querySelector('[id^="new_boost_message_"]');
  }

  function close(area) {
    var menu = menuOf(area);
    var link = area.querySelector('a[href$="/boosts/new"]');
    if (menu) {
      menu.remove();
    }
    if (link) {
      link.hidden = false;
      link.focus();
    }
  }

  // The element of the page that adds a boost goes under the message, so the reactions are one tap away.
  function open(link) {
    var area = link.parentNode;
    fetch(link.href, { credentials: "same-origin", headers: { Accept: "text/html" } })
      .then(function (response) {
        return response.ok ? response.text() : Promise.reject(new Error("no page"));
      })
      .then(function (text) {
        var page = new DOMParser().parseFromString(text, "text/html");
        var found = page.getElementById("new_boost_message_" + area.id.replace(/\D/g, ""));
        if (!found || menuOf(area)) {
          return Promise.reject(new Error("no menu"));
        }

        var menu = document.importNode(found, true);
        menu.querySelector("a[data-cancel]").textContent = "Cancel";
        area.append(menu);
        link.hidden = true;
        menu.querySelector("input").focus();
      })
      .catch(function () {
        location.assign(link.href);
      });
  }

  function apply(text) {
    var holder = document.createElement("template");
    holder.innerHTML = text;
    Array.prototype.forEach.call(holder.content.querySelectorAll("turbo-stream"), function (stream) {
      var target = document.getElementById(stream.getAttribute("target"));
      var template = stream.querySelector("template");
      if (!target) {
        return;
      }
      if (stream.getAttribute("action") === "remove") {
        target.remove();
      } else if (template) {
        Array.prototype.forEach.call(template.content.querySelectorAll("[id]"), function (item) {
          if (document.getElementById(item.id)) {
            item.remove();
          }
        });
        target.append(template.content);
      }
    });
  }

  function send(form, by) {
    var area = areaOf(form);
    var data = new URLSearchParams(new FormData(form));
    // The reaction that was pressed: a button's name and value are not in the form data of a submit made by script.
    if (by && by.name) {
      data.set(by.name, by.value);
    }

    busy = true;
    fetch(form.action, {
      method: "POST",
      credentials: "same-origin",
      headers: { Accept: STREAM, "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" },
      body: data,
    })
      .then(function (response) {
        return response.text().then(function (text) {
          return { status: response.status, text: text };
        });
      })
      .catch(function () {
        return null;
      })
      .then(function (answer) {
        busy = false;
        var pill = form.closest('[id^="boost_"]');
        if (answer && answer.status === 404 && pill) {
          // The boost is gone already (taken off in another tab): the pill goes, and nothing is sent again.
          pill.remove();
          return;
        }
        if (!answer || answer.status !== 200) {
          // A refusal shows its reason on the page that the plain post answers; a lost connection shows the
          // browser's own.
          plain = true;
          if (form.requestSubmit) {
            form.requestSubmit(by || undefined);
          } else {
            form.submit();
          }
          return;
        }

        apply(answer.text);
        if (area.isConnected && menuOf(area)) {
          close(area);
        }
      });
  }

  document.addEventListener("click", function (event) {
    var area = areaOf(event.target);
    var link = event.target.closest ? event.target.closest('a[href$="/boosts/new"]') : null;
    if (event.button || event.metaKey || event.ctrlKey || event.shiftKey || !area) {
      return;
    }

    if (link && link.parentNode === area) {
      event.preventDefault();
      open(link);
    } else if (event.target.closest("a[data-cancel]")) {
      event.preventDefault();
      close(area);
    }
  });

  document.addEventListener("keydown", function (event) {
    var area = areaOf(event.target);
    if (event.key === "Escape" && area && menuOf(area)) {
      close(area);
    }
  });

  document.addEventListener("submit", function (event) {
    if (plain) {
      plain = false;
      return;
    }
    if (!areaOf(event.target)) {
      return;
    }

    event.preventDefault();
    if (!busy) {
      send(event.target, event.submitter);
    }
  });
}

/* Moonrise wall page.
   Plain ES5 so old Android WebViews (the Fire tablet) can run it:
   no let/const, arrow functions, fetch, or template strings.

   Every 15 seconds it asks /api/version whether anything changed, and
   redraws the week only when it has. Event text is set with textContent,
   never innerHTML.

   Tap an event to change, accept or delete it. Tap + on a day to add one.
   Tap the dinner row to set that night's dinner. */

(function () {
  "use strict";

  var POLL_MS = 15000;
  var REDRAW_MS = 5 * 60 * 1000;  // refresh "past" dimming even when quiet

  var state = { version: null, today: null, people: [], groups: null };

  // ---- Helpers --------------------------------------------------------

  function $(id) { return document.getElementById(id); }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }

  // method, url, body (object or null), done(err, data)
  function request(method, url, body, done) {
    var x = new XMLHttpRequest();
    x.open(method, url, true);
    x.timeout = 30000;
    if (body !== null) x.setRequestHeader("Content-Type", "application/json");
    if (method !== "GET") x.setRequestHeader("X-Moonrise", "1");
    x.onreadystatechange = function () {
      if (x.readyState !== 4) return;
      var data = null;
      try { data = JSON.parse(x.responseText); } catch (e) { data = null; }
      if (x.status === 200) { done(null, data); return; }
      var msg = data && data.error ? data.error :
        (x.status === 0 ? "Can't reach the server." : "Error " + x.status + ".");
      done(new Error(msg), data);
    };
    x.ontimeout = function () { done(new Error("The server took too long.")); };
    x.send(body === null ? null : JSON.stringify(body));
  }

  function getJSON(url, done) { request("GET", url, null, done); }

  // "#0072B2" -> "rgba(0,114,178,0.14)"
  function tint(hex, alpha) {
    var n = parseInt(String(hex).replace("#", ""), 16);
    if (isNaN(n)) n = 0x8A8A8A;
    return "rgba(" + ((n >> 16) & 255) + "," + ((n >> 8) & 255) + "," +
      (n & 255) + "," + alpha + ")";
  }

  function pad2(n) { return n < 10 ? "0" + n : String(n); }

  function setOnline(ok) { $("status").hidden = ok; }

  function on(node, fn) {
    node.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      fn(e);
    }, false);
  }

  // "16:30" -> 990, and back
  function toMinutes(t) {
    var p = String(t).split(":");
    return parseInt(p[0], 10) * 60 + parseInt(p[1], 10);
  }
  function fromMinutes(m) {
    m = ((m % 1440) + 1440) % 1440;
    return pad2(Math.floor(m / 60)) + ":" + pad2(m % 60);
  }

  // ---- Clock ----------------------------------------------------------

  function drawClock() {
    var d = new Date();
    var h = d.getHours();
    var ampm = h < 12 ? "AM" : "PM";
    h = h % 12;
    if (h === 0) h = 12;
    $("clock").textContent = h + ":" + pad2(d.getMinutes()) + " " + ampm;
  }

  // ---- Week -----------------------------------------------------------

  function drawEvent(ev) {
    var li = el("li", "ev");
    if (ev.all_day) li.className += " all-day";
    if (ev.pending) li.className += " pending";
    if (ev.past) li.className += " past";
    li.style.borderLeftColor = ev.color;
    li.style.backgroundColor = tint(ev.color, ev.color === "#000000" ? 0.07 : 0.14);

    if (ev.time) li.appendChild(el("span", "ev-time", ev.time));

    var title = el("span", "ev-title");
    if (ev.pending) title.appendChild(el("span", "ev-flag", "Review"));
    title.appendChild(document.createTextNode(ev.title || "(no title)"));
    li.appendChild(title);

    if (ev.who) li.appendChild(el("span", "ev-who", ev.who));
    on(li, function () { openEvent(ev); });
    return li;
  }

  function drawDay(day, first) {
    var col = el("section", "day" + (day.today ? " today" : ""));

    var head = el("div", "day-head");
    head.appendChild(el("span", "day-wd", day.today ? "Today" : day.weekday));
    head.appendChild(el("span", "day-num", day.day));
    // The heading already gives today's month.
    if ((first && !day.today) || day.day === 1) head.appendChild(el("span", "day-month", day.month));
    var add = el("button", "day-add", "+");
    add.type = "button";
    add.setAttribute("aria-label", "Add an event on " + day.weekday + " " + day.day);
    on(add, function () { openNew(day); });
    head.appendChild(add);
    col.appendChild(head);

    var dinner = el("div", "dinner");
    dinner.appendChild(el("span", "dinner-label", "Dinner"));
    if (day.dinner.length) {
      dinner.appendChild(document.createTextNode(day.dinner.join(" + ")));
    } else {
      dinner.className += " empty";
      dinner.appendChild(document.createTextNode("\u2014"));
    }
    on(dinner, function () { openDinner(day); });
    col.appendChild(dinner);

    var list = el("ul", "events");
    if (!day.events.length) list.appendChild(el("li", "no-events", "Nothing planned"));
    for (var i = 0; i < day.events.length; i++) list.appendChild(drawEvent(day.events[i]));
    col.appendChild(list);
    return col;
  }

  function legendDot(color) {
    var dot = el("span", "legend-dot");
    dot.style.backgroundColor = color;
    return dot;
  }

  function drawLegend(people) {
    var box = $("legend");
    box.innerHTML = "";
    function add(color, label) {
      var item = el("span", "legend-item");
      item.appendChild(legendDot(color));
      item.appendChild(document.createTextNode(label));
      box.appendChild(item);
    }
    for (var i = 0; i < people.length; i++) add(people[i].color, people[i].name);
    if (state.groups) {
      add(state.groups.children, "Kids");
      add(state.groups.family, "Family");
    }
  }

  function drawWeek(data) {
    $("heading").textContent = data.heading;
    var week = $("week");
    week.innerHTML = "";
    for (var i = 0; i < data.days.length; i++) week.appendChild(drawDay(data.days[i], i === 0));
    state.people = data.people || [];
    state.groups = data.groups;
    drawLegend(state.people);
  }

  function loadWeek() {
    getJSON("/api/week", function (err, data) {
      setOnline(!err);
      if (err) return;
      state.version = data.version;
      state.today = data.today;
      drawWeek(data);
    });
  }

  function poll() {
    drawClock();
    getJSON("/api/version", function (err, v) {
      setOnline(!err);
      if (err) return;
      if (v.version !== state.version || v.today !== state.today) loadWeek();
    });
  }

  // ---- Edit sheet -----------------------------------------------------

  var sheet = { mode: null, ev: null, day: null, who: {}, busy: false };

  function show(id, yes) { $(id).hidden = !yes; }

  function showError(msg) {
    $("sheet-error").textContent = msg || "";
    show("sheet-error", !!msg);
  }

  function setBusy(yes) {
    sheet.busy = yes;
    var ids = ["b-save", "b-accept", "b-delete", "b-cancel"];
    for (var i = 0; i < ids.length; i++) $(ids[i]).disabled = yes;
  }

  function disarmDelete() {
    var b = $("b-delete");
    b.className = "btn danger";
    b.textContent = "Delete";
  }

  function drawChips() {
    var box = $("f-who");
    box.innerHTML = "";
    function chip(initial, label, color) {
      var b = el("button", "chip" + (sheet.who[initial] ? " on" : ""));
      b.type = "button";
      if (color) b.appendChild(legendDot(color));
      b.appendChild(document.createTextNode(label));
      on(b, function () {
        var was = !!sheet.who[initial];
        if (initial === "F") sheet.who = {};
        else delete sheet.who.F;
        sheet.who[initial] = !was;
        drawChips();
      });
      box.appendChild(b);
    }
    for (var i = 0; i < state.people.length; i++) {
      var p = state.people[i];
      chip(p.initial, p.name, p.color);
    }
    chip("F", "Everyone", state.groups ? state.groups.family : null);
  }

  function syncAllDay() {
    var allDay = $("f-allday").checked;
    show("f-times", !allDay);
    show("f-lastday", allDay);
  }

  function openSheet(mode) {
    sheet.mode = mode;
    showError("");
    setBusy(false);
    disarmDelete();
    show("form-event", mode !== "dinner");
    show("form-dinner", mode === "dinner");
    show("b-delete", mode === "edit" || (mode === "dinner" && sheet.day.dinner.length));
    show("b-accept", mode === "edit" && sheet.ev.pending);
    show("sheet", true);
  }

  function closeSheet() {
    show("sheet", false);
    sheet.mode = null;
    if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
  }

  function fillForm(f) {
    $("f-title").value = f.title || "";
    $("f-date").value = f.date;
    $("f-allday").checked = !!f.all_day;
    $("f-start").value = f.start_time || "09:00";
    $("f-end").value = f.end_time || fromMinutes(toMinutes(f.start_time || "09:00") + 60);
    $("f-enddate").value = f.end_date || f.date;
    sheet.who = {};
    var who = (f.who || "").split(" ");
    for (var i = 0; i < who.length; i++) if (who[i]) sheet.who[who[i]] = true;
    drawChips();
    syncAllDay();
  }

  function openNew(day) {
    sheet.ev = null;
    sheet.day = day;
    var start = "09:00";
    if (day.today) {
      var now = new Date();
      start = fromMinutes(Math.min(23, now.getHours() + 1) * 60);
    }
    $("sheet-title").textContent = "Add event";
    $("sheet-note").textContent = day.weekday + " " + day.month + " " + day.day;
    fillForm({ date: day.date, start_time: start, all_day: false });
    openSheet("add");
    $("f-title").focus();
  }

  function openEvent(ev) {
    sheet.ev = ev;
    sheet.day = null;
    $("sheet-title").textContent = ev.pending ? "Review event" : "Change event";
    $("sheet-note").textContent = ev.repeats ? "Repeats. Changes apply to this day only." :
      (ev.pending ? "Added from an email." : "");
    fillForm(ev);
    openSheet("edit");
  }

  function openDinner(day) {
    sheet.ev = null;
    sheet.day = day;
    $("sheet-title").textContent = "Dinner";
    $("sheet-note").textContent = day.weekday + " " + day.month + " " + day.day;
    $("f-dinner").value = day.dinner.join(" + ");
    openSheet("dinner");
    $("f-dinner").focus();
  }

  function readForm() {
    var who = [];
    for (var k in sheet.who) if (sheet.who.hasOwnProperty(k) && sheet.who[k]) who.push(k);
    var allDay = $("f-allday").checked;
    return {
      calendar: sheet.ev ? sheet.ev.calendar : "family",
      title: $("f-title").value,
      who: who,
      date: $("f-date").value,
      all_day: allDay,
      start_time: allDay ? "" : $("f-start").value,
      end_time: allDay ? "" : $("f-end").value,
      end_date: allDay ? $("f-enddate").value : "",
      // Saving a review item counts as reviewing it.
      pending: false
    };
  }

  function evPath(ev) {
    return "/api/events/" + encodeURIComponent(ev.calendar) + "/" + encodeURIComponent(ev.id);
  }

  function send(method, url, body) {
    if (sheet.busy) return;
    setBusy(true);
    showError("");
    request(method, url, body, function (err) {
      setBusy(false);
      if (err) { showError(err.message); return; }
      closeSheet();
      loadWeek();
    });
  }

  // Keep the end an hour after the start when the start moves.
  var lastStart = null;
  $("f-start").addEventListener("focus", function () { lastStart = $("f-start").value; }, false);
  $("f-start").addEventListener("change", function () {
    var s = $("f-start").value;
    if (!s || !lastStart) return;
    var e = $("f-end").value;
    var length = e ? toMinutes(e) - toMinutes(lastStart) : 60;
    if (length <= 0) length = 60;
    $("f-end").value = fromMinutes(toMinutes(s) + length);
    lastStart = s;
  }, false);

  $("f-allday").addEventListener("change", syncAllDay, false);

  $("f-date").addEventListener("change", function () {
    if ($("f-enddate").value < $("f-date").value) $("f-enddate").value = $("f-date").value;
  }, false);

  on($("b-cancel"), closeSheet);

  on($("sheet"), function (e) {
    if (e.target === $("sheet")) closeSheet();   // tap outside the box
  });
  // Taps inside the box must not reach the backdrop handler.
  $("sheet").firstElementChild.addEventListener("click", function (e) {
    e.stopPropagation();
  }, false);

  on($("b-save"), function () {
    if (sheet.mode === "dinner") {
      send("PUT", "/api/dinner/" + sheet.day.date, { title: $("f-dinner").value });
    } else if (sheet.mode === "edit") {
      send("PATCH", evPath(sheet.ev), readForm());
    } else {
      send("POST", "/api/events", readForm());
    }
  });

  on($("b-accept"), function () {
    send("POST", evPath(sheet.ev) + "/accept", {});
  });

  // Delete takes two taps instead of a pop-up, which can lock a kiosk.
  on($("b-delete"), function () {
    var b = $("b-delete");
    if (b.className.indexOf("armed") < 0) {
      b.className = "btn danger armed";
      b.textContent = "Tap again to delete";
      return;
    }
    if (sheet.mode === "dinner") {
      send("PUT", "/api/dinner/" + sheet.day.date, { title: "" });
    } else {
      send("DELETE", evPath(sheet.ev), null);
    }
  });

  // Enter in a text box saves.
  function enterSaves(id) {
    $(id).addEventListener("keydown", function (e) {
      if (e.keyCode === 13) { e.preventDefault(); $("b-save").click(); }
    }, false);
  }
  enterSaves("f-title");
  enterSaves("f-dinner");

  // ---- Start ----------------------------------------------------------

  // Reload the whole page at 3:30 AM so it picks up code changes on the
  // server without anyone touching the tablet.
  function scheduleNightlyReload() {
    var now = new Date();
    var next = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 3, 30, 0);
    if (next <= now) next.setDate(next.getDate() + 1);
    setTimeout(function () {
      if (sheet.mode) { scheduleNightlyReload(); return; }
      window.location.reload();
    }, next - now);
  }

  drawClock();
  loadWeek();
  setInterval(poll, POLL_MS);
  setInterval(loadWeek, REDRAW_MS);
  scheduleNightlyReload();
})();

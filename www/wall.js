/* Moonrise wall page.
   Plain ES5 so old Android WebViews (the Fire tablet) can run it:
   no let/const, arrow functions, fetch, or template strings.

   Every 15 seconds it asks /api/version whether anything changed, and
   redraws the week only when it has. Event text is set with textContent,
   never innerHTML.

   Tap an event to change, accept or delete it; for a repeating event,
   choose this day or the whole series. Tap + on a day to add one, once or
   repeating (as one series or as separate events). Tap the dinner row to
   set that night's dinner. */

(function () {
  "use strict";

  var POLL_MS = 15000;
  var REDRAW_MS = 5 * 60 * 1000;  // refresh "past" dimming even when quiet

  var state = { version: null, today: null, people: [], groups: null, reviews: [] };

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
    drawReviewButton(data.reviews || []);
  }

  // Imports awaiting review, from any date. The week only shows seven days,
  // so this is how later ones get checked.
  function drawReviewButton(reviews) {
    state.reviews = reviews;
    var b = $("review-btn");
    b.hidden = !reviews.length;
    b.textContent = reviews.length + " to review";
  }

  function loadWeek(then) {
    getJSON("/api/week", function (err, data) {
      setOnline(!err);
      if (err) return;
      state.version = data.version;
      state.today = data.today;
      drawWeek(data);
      if (typeof then === "function") then();
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

  var sheet = { mode: null, ev: null, day: null, who: {}, busy: false,
                days: {}, as: "series", scope: "one" };

  var WEEKDAYS = [["MO", "Mon"], ["TU", "Tue"], ["WE", "Wed"], ["TH", "Thu"],
                  ["FR", "Fri"], ["SA", "Sat"], ["SU", "Sun"]];
  var CODE_BY_WDAY = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
  var DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  // "2026-11-03" -> Date at local noon (noon dodges DST edges)
  function parseDay(s) {
    var p = String(s).split("-");
    return new Date(parseInt(p[0], 10), parseInt(p[1], 10) - 1, parseInt(p[2], 10), 12);
  }

  function ordinal(n) {
    var t = n % 100;
    if (t >= 11 && t <= 13) return n + "th";
    return n + (["th", "st", "nd", "rd"][n % 10] || "th");
  }

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

  // ---- Repeat controls (new events) ----

  function drawRepeatOptions() {
    var sel = $("f-repeat");
    var keep = sel.value || "none";
    var d = parseDay($("f-date").value || state.today);
    var nth = Math.ceil(d.getDate() / 7);
    var nthWord = nth === 5 ? "last" : ["first", "second", "third", "fourth"][nth - 1];
    var opts = [
      ["none", "Doesn't repeat"],
      ["daily", "Every day"],
      ["weekly", "Every week"],
      ["biweekly", "Every 2 weeks"],
      ["monthly_date", "Monthly on the " + ordinal(d.getDate())],
      ["monthly_weekday", "Monthly on the " + nthWord + " " + DAY_NAMES[d.getDay()]],
      ["yearly", "Every year on " + MONTHS[d.getMonth()] + " " + d.getDate()]
    ];
    sel.innerHTML = "";
    for (var i = 0; i < opts.length; i++) {
      var o = el("option", null, opts[i][1]);
      o.value = opts[i][0];
      sel.appendChild(o);
    }
    sel.value = keep;
  }

  function drawDayChips() {
    var box = $("f-days");
    box.innerHTML = "";
    for (var i = 0; i < WEEKDAYS.length; i++) {
      (function (code, label) {
        var b = el("button", "chip day-chip" + (sheet.days[code] ? " on" : ""), label);
        b.type = "button";
        on(b, function () {
          sheet.days[code] = !sheet.days[code];
          drawDayChips();
        });
        box.appendChild(b);
      })(WEEKDAYS[i][0], WEEKDAYS[i][1]);
    }
  }

  function drawAsChips() {
    var box = $("f-as");
    box.innerHTML = "";
    var opts = [["series", "One series"], ["separate", "Separate events"]];
    for (var i = 0; i < opts.length; i++) {
      (function (value, label) {
        var b = el("button", "chip" + (sheet.as === value ? " on" : ""), label);
        b.type = "button";
        on(b, function () {
          sheet.as = value;
          // Separate copies need an end.
          if (value === "separate" && $("f-ends").value === "never") $("f-ends").value = "after";
          syncRepeat();
        });
        box.appendChild(b);
      })(opts[i][0], opts[i][1]);
    }
    $("f-as-hint").textContent = sheet.as === "series" ?
      "Later you can change one day or all of them at once." :
      "Each one is its own event, changed on its own.";
  }

  function syncRepeat() {
    var freq = $("f-repeat").value;
    var repeating = freq !== "none";
    var weekly = freq === "weekly" || freq === "biweekly";
    var ends = $("f-ends").value;
    show("f-ends-box", repeating);
    show("f-until-box", repeating && ends === "on");
    show("f-count-box", repeating && ends === "after");
    show("f-days-box", weekly);
    show("f-as-box", repeating);
    if (weekly) {
      var any = false;
      for (var k in sheet.days) if (sheet.days.hasOwnProperty(k) && sheet.days[k]) any = true;
      if (!any) sheet.days[CODE_BY_WDAY[parseDay($("f-date").value).getDay()]] = true;
      drawDayChips();
    }
    if (repeating) drawAsChips();
  }

  function resetRepeat(date) {
    sheet.days = {};
    sheet.as = "series";
    $("f-repeat").value = "none";
    drawRepeatOptions();
    $("f-repeat").value = "none";
    $("f-ends").value = "never";
    $("f-count").value = "10";
    var d = parseDay(date);
    d.setMonth(d.getMonth() + 3);
    $("f-until").value = d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate());
    syncRepeat();
  }

  function readRepeat() {
    var days = [];
    for (var k in sheet.days) if (sheet.days.hasOwnProperty(k) && sheet.days[k]) days.push(k);
    return {
      freq: $("f-repeat").value,
      days: days,
      ends: $("f-ends").value,
      until: $("f-until").value,
      count: parseInt($("f-count").value, 10),
      as: sheet.as
    };
  }

  // ---- This day / whole series (repeating events) ----

  function drawScopeChips() {
    var box = $("f-scope");
    box.innerHTML = "";
    var opts = [["one", "This day"], ["series", "Whole series"]];
    for (var i = 0; i < opts.length; i++) {
      (function (value, label) {
        var b = el("button", "chip" + (sheet.scope === value ? " on" : ""), label);
        b.type = "button";
        on(b, function () {
          sheet.scope = value;
          disarmDelete();
          drawScopeChips();
        });
        box.appendChild(b);
      })(opts[i][0], opts[i][1]);
    }
    var whole = sheet.scope === "series";
    // A whole series keeps its days; it can't switch between all day and timed.
    $("f-date").disabled = whole;
    $("f-allday").disabled = whole;
    $("f-scope-hint").textContent = whole ?
      "Every day in the series gets this name, people and time. The days stay the same." :
      "Only this day changes.";
  }

  function openSheet(mode) {
    sheet.mode = mode;
    showError("");
    setBusy(false);
    disarmDelete();
    show("form-event", mode === "add" || mode === "edit");
    show("form-dinner", mode === "dinner");
    show("review-list", mode === "reviews");
    show("b-save", mode !== "reviews");
    $("b-cancel").textContent = mode === "reviews" ? "Close" : "Cancel";
    show("b-delete", mode === "edit" || (mode === "dinner" && sheet.day.dinner.length > 0));
    show("b-accept", mode === "edit" && sheet.ev.pending);
    show("f-repeat-box", mode === "add");
    var repeating = mode === "edit" && sheet.ev.repeats;
    show("f-scope-box", repeating);
    sheet.scope = "one";
    if (repeating) drawScopeChips();
    else { $("f-date").disabled = false; $("f-allday").disabled = false; }
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

  function openReviews() {
    sheet.ev = null;
    sheet.day = null;
    sheet.fromReviews = false;
    $("sheet-title").textContent = "To review";
    $("sheet-note").textContent = "Added from email. Tap one to check it.";
    var list = $("review-list");
    list.innerHTML = "";
    for (var i = 0; i < state.reviews.length; i++) {
      (function (ev) {
        var li = el("li", "review-item");
        li.style.borderLeftColor = ev.color;
        li.style.backgroundColor = tint(ev.color, ev.color === "#000000" ? 0.07 : 0.14);
        li.appendChild(el("span", "review-when", ev.when));
        li.appendChild(el("span", "review-title", ev.title || "(no title)"));
        if (ev.who) li.appendChild(el("span", "ev-who", ev.who));
        on(li, function () {
          openEvent(ev);
          sheet.fromReviews = true;
        });
        list.appendChild(li);
      })(state.reviews[i]);
    }
    openSheet("reviews");
  }

  function openNew(day) {
    sheet.fromReviews = false;
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
    resetRepeat(day.date);
    openSheet("add");
    $("f-title").focus();
  }

  function openEvent(ev) {
    sheet.fromReviews = false;
    sheet.ev = ev;
    sheet.day = null;
    $("sheet-title").textContent = ev.pending ? "Review event" : "Change event";
    $("sheet-note").textContent = ev.repeats ? "Part of a repeating series." :
      (ev.pending ? "Added from an email." : "");
    fillForm(ev);
    openSheet("edit");
  }

  function openDinner(day) {
    sheet.fromReviews = false;
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
      pending: false,
      "repeat": sheet.mode === "add" ? readRepeat() : null,
      scope: sheet.scope
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
      var back = sheet.fromReviews;
      closeSheet();
      loadWeek(function () {
        if (back && state.reviews.length) openReviews();
      });
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
    if (sheet.mode === "add") drawRepeatOptions();
  }, false);

  $("f-repeat").addEventListener("change", syncRepeat, false);
  $("f-ends").addEventListener("change", syncRepeat, false);

  on($("b-cancel"), function () {
    // From an item opened off the review list, Cancel goes back to the list.
    if (sheet.fromReviews) openReviews();
    else closeSheet();
  });

  on($("review-btn"), openReviews);

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
    var whole = sheet.mode === "edit" && sheet.ev.repeats && sheet.scope === "series";
    if (b.className.indexOf("armed") < 0) {
      b.className = "btn danger armed";
      b.textContent = whole ? "Tap again to delete all" : "Tap again to delete";
      return;
    }
    if (sheet.mode === "dinner") {
      send("PUT", "/api/dinner/" + sheet.day.date, { title: "" });
    } else {
      send("DELETE", evPath(sheet.ev) + (whole ? "?scope=series" : ""), null);
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

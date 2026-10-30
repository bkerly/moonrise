/* Moonrise wall page.
   Plain ES5 so old Android WebViews (the Fire tablet) can run it:
   no let/const, arrow functions, fetch, or template strings.

   Every 15 seconds it asks /api/version whether anything changed, and
   redraws the week only when it has. Event text is set with textContent,
   never innerHTML. */

(function () {
  "use strict";

  var POLL_MS = 15000;
  var REDRAW_MS = 5 * 60 * 1000;  // refresh "past" dimming even when quiet

  var state = { version: null, today: null, people: [] };

  // ---- Helpers --------------------------------------------------------

  function $(id) { return document.getElementById(id); }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }

  function getJSON(url, done) {
    var x = new XMLHttpRequest();
    x.open("GET", url, true);
    x.timeout = 10000;
    x.onreadystatechange = function () {
      if (x.readyState !== 4) return;
      if (x.status !== 200) { done(new Error("HTTP " + x.status)); return; }
      var data;
      try { data = JSON.parse(x.responseText); }
      catch (e) { done(e); return; }
      done(null, data);
    };
    x.ontimeout = function () { done(new Error("timeout")); };
    x.send();
  }

  // "#0072B2" -> "rgba(0,114,178,0.14)"
  function tint(hex, alpha) {
    var n = parseInt(String(hex).replace("#", ""), 16);
    if (isNaN(n)) n = 0x8A8A8A;
    return "rgba(" + ((n >> 16) & 255) + "," + ((n >> 8) & 255) + "," +
      (n & 255) + "," + alpha + ")";
  }

  function pad2(n) { return n < 10 ? "0" + n : String(n); }

  function setOnline(ok) {
    $("status").hidden = ok;
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
    return li;
  }

  function drawDay(day, first) {
    var col = el("section", "day" + (day.today ? " today" : ""));

    var head = el("div", "day-head");
    head.appendChild(el("span", "day-wd", day.today ? "Today" : day.weekday));
    head.appendChild(el("span", "day-num", day.day));
    if (first || day.day === 1) head.appendChild(el("span", "day-month", day.month));
    col.appendChild(head);

    var dinner = el("div", "dinner");
    dinner.appendChild(el("span", "dinner-label", "Dinner"));
    if (day.dinner.length) {
      dinner.appendChild(document.createTextNode(day.dinner.join(" + ")));
    } else {
      dinner.className += " empty";
      dinner.appendChild(document.createTextNode("—"));
    }
    col.appendChild(dinner);

    var list = el("ul", "events");
    if (!day.events.length) list.appendChild(el("li", "no-events", "Nothing planned"));
    for (var i = 0; i < day.events.length; i++) list.appendChild(drawEvent(day.events[i]));
    col.appendChild(list);
    return col;
  }

  function drawLegend(people) {
    var box = $("legend");
    box.innerHTML = "";
    function add(color, label) {
      var item = el("span", "legend-item");
      var dot = el("span", "legend-dot");
      dot.style.backgroundColor = color;
      item.appendChild(dot);
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
    state.groups = data.groups;
    drawLegend(data.people || []);
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

  // Reload the whole page at 3:30 AM so it picks up code changes on the
  // server without anyone touching the tablet.
  function scheduleNightlyReload() {
    var now = new Date();
    var next = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 3, 30, 0);
    if (next <= now) next.setDate(next.getDate() + 1);
    setTimeout(function () { window.location.reload(); }, next - now);
  }

  drawClock();
  loadWeek();
  setInterval(poll, POLL_MS);
  setInterval(loadWeek, REDRAW_MS);
  scheduleNightlyReload();
})();

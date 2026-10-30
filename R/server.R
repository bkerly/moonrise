# R/server.R
#
# The web server the wall tablet and phones talk to. It runs in the same
# R process as the sync loop: plumber drives the `later` event loop, so
# the sync and import timers keep firing between requests.
#
#   GET    /                               redirects to /wall/
#   GET    /favicon.ico                    redirects to the icon
#   GET    /wall/                          the wall page (files in www/)
#   GET    /api/version                    polled to know when to redraw
#   GET    /api/week?start=YYYY-MM-DD      the week view
#   POST   /api/events                     add an event (body "repeat": see R/repeat.R)
#   PATCH  /api/events/<calendar>/<id>     change an event (body "scope": one | series)
#   POST   /api/events/<calendar>/<id>/accept   remove the "?"
#   DELETE /api/events/<calendar>/<id>     delete an event (?scope=one | series)
#   PUT    /api/dinner/<date>              set or clear one night's dinner
#
# Writes go to Google first; then that calendar is synced at once, so the
# local copy never disagrees with Google.
#
# Writes must carry the header "X-Moonrise: 1". Browsers won't send a
# custom header to another site without asking first, and this server
# never says yes, so a web page elsewhere can't use a visitor's browser to
# change the calendar.

moonrise_router <- function(cfg, con, google = NULL, www = "www") {
  json <- plumber::serializer_unboxed_json(na = "null")

  pr <- plumber::pr()

  pr <- plumber::pr_get(pr, "/", function(res) {
    res$status <- 302
    res$setHeader("Location", "/wall/")
    ""
  }, serializer = plumber::serializer_text())

  # Browsers ask for /favicon.ico on their own; send them to the PNG.
  pr <- plumber::pr_get(pr, "/favicon.ico", function(res) {
    res$status <- 301
    res$setHeader("Location", "/wall/icons/favicon-32.png")
    ""
  }, serializer = plumber::serializer_text())

  pr <- plumber::pr_get(pr, "/api/version", function(res) {
    res$setHeader("Cache-Control", "no-store")
    v <- store_version(con)
    v$today <- format(as.Date(Sys.time(), tz = cfg$tz))
    v
  }, serializer = json)

  pr <- plumber::pr_get(pr, "/api/week", function(res, start = "") {
    res$setHeader("Cache-Control", "no-store")
    day <- if (nzchar(start)) {
      tryCatch(as.Date(start, format = "%Y-%m-%d"), error = function(e) NA)
    } else NULL
    if (!is.null(day) && is.na(day)) {
      res$status <- 400
      return(list(error = "start must look like 2026-11-02"))
    }
    week_payload(con, cfg, start = day)
  }, serializer = json)

  # ---- Writes --------------------------------------------------------------

  # Runs a write, then syncs the calendar it touched. Turns errors into
  # a 400 with a message the page can show.
  write <- function(req, res, calendar, fn) {
    res$setHeader("Cache-Control", "no-store")
    if (!identical(req$HTTP_X_MOONRISE, "1")) {
      res$status <- 403
      return(list(error = "Missing X-Moonrise header."))
    }
    if (is.null(google)) {
      res$status <- 503
      return(list(error = "This server can't write to Google."))
    }
    tryCatch({
      if (!calendar %in% names(cfg$calendars)) {
        stop("Unknown calendar: ", calendar, call. = FALSE)
      }
      fn()
      sync_calendar(google, con, cfg, calendar)
      list(ok = TRUE, version = store_version(con)$version)
    }, error = function(e) {
      res$status <- 400
      list(error = google_message(conditionMessage(e)))
    })
  }

  body_of <- function(req) {
    b <- req$body
    if (is.null(b) || !is.list(b)) list() else b
  }

  pr <- plumber::pr_post(pr, "/api/events", function(req, res) {
    b   <- body_of(req)
    cal <- as.character(b$calendar %||% "family")
    write(req, res, cal, function() add_event(google, cfg, cal, b))
  }, serializer = json)

  pr <- plumber::pr_handle(pr, "PATCH", "/api/events/<calendar>/<id>",
    function(req, res, calendar, id) {
      b <- body_of(req)
      scope <- as.character(b$scope %||% "one")
      write(req, res, calendar, function() {
        change_event(google, cfg, con, calendar, id, b, scope)
      })
    }, serializer = json)

  pr <- plumber::pr_post(pr, "/api/events/<calendar>/<id>/accept",
    function(req, res, calendar, id) {
      write(req, res, calendar, function() {
        event_accept(google, cfg, con, calendar, id)
      })
    }, serializer = json)

  pr <- plumber::pr_delete(pr, "/api/events/<calendar>/<id>",
    function(req, res, calendar, id, scope = "one") {
      write(req, res, calendar, function() {
        remove_event(google, cfg, con, calendar, id, scope)
      })
    }, serializer = json)

  pr <- plumber::pr_put(pr, "/api/dinner/<date>", function(req, res, date) {
    b <- body_of(req)
    write(req, res, "dinner", function() {
      set_dinner(google, cfg, con, date, as.character(b$title %||% ""))
    })
  }, serializer = json)

  plumber::pr_static(pr, "/wall", www)
}

# Google's error text is long; keep the part a person can use.
google_message <- function(msg) {
  msg <- sub("(?s)^Client error: \\(\\d+\\)[^\\n]*\\n", "", msg, perl = TRUE)
  msg <- strsplit(msg, "\n", fixed = TRUE)[[1]][1]
  if (is.na(msg) || !nzchar(msg)) "Something went wrong." else msg
}

# Best guess at this machine's address on the home network, for the
# startup message. Returns NULL if it can't tell.
lan_address <- function() {
  try_cmd <- function(cmd, args) {
    out <- tryCatch(suppressWarnings(system2(cmd, args, stdout = TRUE,
                                             stderr = FALSE)),
                    error = function(e) character())
    out <- trimws(unlist(strsplit(out, "\\s+")))
    out[grepl("^\\d+\\.\\d+\\.\\d+\\.\\d+$", out)][1]
  }
  ip <- if (Sys.info()[["sysname"]] == "Darwin") {
    try_cmd("ipconfig", c("getifaddr", "en0"))
  } else {
    try_cmd("hostname", "-I")
  }
  if (length(ip) && !is.na(ip)) ip else NULL
}

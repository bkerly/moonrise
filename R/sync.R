# R/sync.R
#
# Keeps the local store in step with Google Calendar. Each pass, per
# calendar:
#
# 1. Change check. List events with the saved sync token. Google returns
#    only what changed since last time, usually nothing. A sync token can't
#    be combined with a date range, so this step doesn't expand repeating
#    events; it only answers "did anything change?"
#
# 2. Window refresh, only if something changed, on the first run, after an
#    expired token, or once an hour. List the window (days_back to
#    days_ahead) with repeating events expanded, and replace the stored
#    copy in one transaction.
#
# The new sync token is saved only after the refresh succeeds, so a failed
# refresh is retried on the next pass.
#
# Google docs: https://developers.google.com/workspace/calendar/api/guides/sync

events_path <- "calendar/v3/calendars/{calendarId}/events"

moonrise_log <- function(fmt, ...) {
  cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), sprintf(fmt, ...), "\n")
  flush(stdout())
}

# ---- Time parsing ----------------------------------------------------------

# Google sends "2026-10-30T11:34:59-06:00" or "...Z". R's %z needs "-0600".
parse_rfc3339 <- function(x) {
  x <- sub("Z$", "+0000", x)
  x <- sub("([+-]\\d{2}):(\\d{2})$", "\\1\\2", x, perl = TRUE)
  as.numeric(as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%OS%z", tz = "UTC"))
}

# All-day events start and end at local midnight. Google's end date is the
# day after the last day.
parse_day <- function(x, tz) {
  as.numeric(as.POSIXct(x, format = "%Y-%m-%d", tz = tz))
}

# ---- Google events to table rows ------------------------------------------

event_rows <- function(items, cfg) {
  items <- Filter(function(e) !identical(e[["status"]], "cancelled"), items)
  n     <- length(items)
  pick  <- function(f) vapply(items, function(e) f(e) %||% NA_character_, "")

  # [[ ]] not $: `$` on a list matches partial names, so e$start$date
  # would quietly return dateTime.
  all_day <- vapply(items, function(e) !is.null(e[["start"]][["date"]]), TRUE)
  start   <- pick(function(e) e[["start"]][["dateTime"]] %||% e[["start"]][["date"]])
  end     <- pick(function(e) e[["end"]][["dateTime"]] %||% e[["end"]][["date"]] %||%
                    e[["start"]][["dateTime"]] %||% e[["start"]][["date"]])

  start_ts <- ifelse(all_day, parse_day(start, cfg$tz), parse_rfc3339(start))
  end_ts   <- ifelse(all_day, parse_day(end, cfg$tz), parse_rfc3339(end))

  raw    <- pick(function(e) e[["summary"]])
  parsed <- parse_titles(raw, names(cfg$family))

  data.frame(
    id           = pick(function(e) e[["id"]]),
    raw_title    = raw,
    title        = parsed$title,
    who          = parsed$who,
    pending      = as.integer(parsed$pending),
    all_day      = as.integer(all_day),
    start        = start,
    end          = end,
    start_ts     = as.numeric(start_ts),
    end_ts       = as.numeric(end_ts),
    location     = pick(function(e) e[["location"]]),
    description  = pick(function(e) e[["description"]]),
    recurring_id = pick(function(e) e[["recurringEventId"]]),
    updated      = pick(function(e) e[["updated"]]),
    html_link    = pick(function(e) e[["htmlLink"]]),
    stringsAsFactors = FALSE
  )[seq_len(n), , drop = FALSE]
}

# ---- Google requests -------------------------------------------------------

# Step 1. Returns the number of changed items and the new sync token.
# With token = NULL this is the first full listing, which only serves to
# get a token. Signals moonrise_gone if the token has expired.
change_check <- function(google, calendar_id, token) {
  n    <- 0
  page <- NULL
  repeat {
    res <- google("GET", events_path, params = list(
      calendarId   = calendar_id,
      syncToken    = token,
      pageToken    = page,
      singleEvents = "false",
      maxResults   = 2500
    ))
    n    <- n + length(res$items)
    page <- res$nextPageToken
    if (is.null(page)) break
  }
  if (is.null(res$nextSyncToken)) stop("Google sent no sync token.")
  list(n = n, token = res$nextSyncToken)
}

# Step 2. All event instances in the window, as table rows.
fetch_window <- function(google, calendar_id, cfg, now) {
  today <- as.Date(now, tz = cfg$tz)
  from  <- as.POSIXct(format(today - cfg$sync$days_back),  tz = cfg$tz)
  to    <- as.POSIXct(format(today + cfg$sync$days_ahead), tz = cfg$tz)

  items <- list()
  page  <- NULL
  repeat {
    res <- google("GET", events_path, params = list(
      calendarId   = calendar_id,
      timeMin      = rfc3339(from),
      timeMax      = rfc3339(to),
      singleEvents = "true",
      orderBy      = "startTime",
      maxResults   = 2500,
      pageToken    = page
    ))
    items <- c(items, res$items %||% list())
    page  <- res$nextPageToken
    if (is.null(page)) break
  }
  event_rows(items, cfg)
}

# ---- One calendar, one pass -----------------------------------------------

sync_calendar <- function(google, con, cfg, name, now = Sys.time(), force = FALSE) {
  id    <- cfg$calendars[[name]]
  st    <- store_state(con, name)
  token <- st$sync_token
  if (length(token) == 0 || is.na(token)) token <- NULL

  reason <- if (is.null(token)) "first sync" else if (force) "startup refresh" else NULL
  check  <- tryCatch(
    change_check(google, id, token),
    moonrise_gone = function(e) NULL
  )
  if (is.null(check)) {
    reason <- "sync token expired"
    check  <- change_check(google, id, NULL)
  }

  if (is.null(reason) && check$n > 0) {
    reason <- sprintf("%d change(s)", check$n)
  }
  last <- st$last_refresh
  if (is.null(reason) &&
      (is.na(last) || as.numeric(now) - last >= cfg$sync$refresh_minutes * 60)) {
    reason <- "scheduled refresh"
  }

  out <- list(calendar = name, reason = reason)
  if (!is.null(reason)) {
    rows        <- fetch_window(google, id, cfg, now)
    out$events  <- nrow(rows)
    out$changed <- store_replace_events(con, name, rows)
    store_set_state(con, name, last_refresh = as.numeric(now))
  }
  store_set_state(con, name, sync_token = check$token,
                  last_check = as.numeric(now), last_error = NA_character_)
  out
}

# ---- All calendars ---------------------------------------------------------

# One pass over every calendar. Errors are caught per calendar, saved in
# sync_state, and logged only when they first appear or change, so a
# Wi-Fi outage doesn't fill the log.
sync_all <- function(google, con, cfg, now = Sys.time(), quiet = FALSE, force = FALSE) {
  for (name in names(cfg$calendars)) {
    before <- store_state(con, name)$last_error
    res <- tryCatch(
      sync_calendar(google, con, cfg, name, now, force),
      error = function(e) list(calendar = name, error = conditionMessage(e))
    )

    if (!is.null(res$error)) {
      store_set_state(con, name, last_error = res$error)
      if (!identical(before, res$error)) {
        moonrise_log("%s: error: %s", name, res$error)
      }
      next
    }
    if (!is.na(before)) moonrise_log("%s: working again", name)
    if (!quiet && !is.null(res$reason)) {
      moonrise_log("%s: %s; %d event%s in window%s", name, res$reason,
                   res$events, if (res$events == 1) "" else "s",
                   if (isTRUE(res$changed)) ", updated" else "")
    }
  }
  invisible(TRUE)
}

# Runs sync_all every cfg$sync$every_seconds using `later`, so the same
# loop can share a process with the plumber web server later on.
start_sync_loop <- function(google, con, cfg) {
  # The first pass refreshes the whole window, so a changed setting (such
  # as days_back) takes effect at startup rather than within the hour.
  first <- TRUE
  tick <- function() {
    sync_all(google, con, cfg, force = first)
    first <<- FALSE
    later::later(tick, cfg$sync$every_seconds)
  }
  tick()
}

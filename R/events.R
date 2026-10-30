# R/events.R
#
# Turning a form (from the wall page or an email import) into a Google
# Calendar event, and writing it.
#
# A form is a list:
#   title       "Swim Lessons"
#   who         c("V", "N")          initials; "F" for the whole family
#   date        "2026-11-03"         first day
#   all_day     TRUE / FALSE
#   start_time  "16:00"              24-hour, ignored when all_day
#   end_time    "17:00"              optional; defaults to an hour later
#   end_date    "2026-11-05"         optional, all-day only, last day shown
#   pending     TRUE / FALSE         "?" prefix: awaiting review
#
# Times go to Google as local clock times plus the calendar's time zone,
# so Google handles daylight saving.

# "V N - Swim Lessons", with "? " in front when pending.
compose_title <- function(title, who = character(), pending = FALSE) {
  who   <- unique(who[nzchar(who)])
  title <- trimws(title)
  out   <- if (length(who)) paste(paste(who, collapse = " "), "-", title) else title
  if (isTRUE(pending)) paste("?", out) else out
}

valid_date <- function(x) {
  is.character(x) && length(x) == 1 && grepl("^\\d{4}-\\d{2}-\\d{2}$", x) &&
    !is.na(as.Date(x, format = "%Y-%m-%d"))
}

valid_time <- function(x) {
  is.character(x) && length(x) == 1 &&
    grepl("^([01]?\\d|2[0-3]):[0-5]\\d$", x)
}

# "9:05" -> minutes after midnight
time_minutes <- function(x) {
  p <- as.integer(strsplit(x, ":", fixed = TRUE)[[1]])
  p[1] * 60 + p[2]
}

minutes_time <- function(m) sprintf("%02d:%02d", m %/% 60, m %% 60)

# Checks and fills in a form. Returns the cleaned form, or stops with a
# message the wall page can show.
clean_form <- function(form, cfg) {
  f <- list(
    title      = trimws(as.character(form$title %||% "")),
    who        = as.character(unlist(form$who %||% character())),
    date       = as.character(form$date %||% ""),
    all_day    = isTRUE(as.logical(form$all_day)),
    start_time = as.character(form$start_time %||% ""),
    end_time   = as.character(form$end_time %||% ""),
    end_date   = as.character(form$end_date %||% ""),
    pending    = isTRUE(as.logical(form$pending))
  )
  if (!nzchar(f$title)) stop("Add a title.", call. = FALSE)
  if (nchar(f$title) > 200) stop("That title is too long.", call. = FALSE)
  if (!valid_date(f$date)) stop("Pick a date.", call. = FALSE)

  known <- c(names(cfg$family), "F")
  f$who <- unique(f$who[f$who %in% known])
  if ("F" %in% f$who) f$who <- "F"

  if (f$all_day) {
    if (!nzchar(f$end_date)) f$end_date <- f$date
    if (!valid_date(f$end_date) || as.Date(f$end_date) < as.Date(f$date)) {
      stop("The last day can't be before the first day.", call. = FALSE)
    }
    f$start_time <- ""
    f$end_time   <- ""
  } else {
    if (!valid_time(f$start_time)) stop("Pick a start time.", call. = FALSE)
    s <- time_minutes(f$start_time)
    e <- if (valid_time(f$end_time)) time_minutes(f$end_time) else s + 60
    if (e == s) e <- s + 60
    if (e < s) e <- e + 24 * 60      # an end earlier than the start is the next day
    f$start_time <- minutes_time(s)
    # An end past midnight rolls into the next day.
    f$end_date   <- format(as.Date(f$date) + e %/% (24 * 60))
    f$end_time   <- minutes_time(e %% (24 * 60))
  }
  f
}

# Google event fields for a cleaned form.
event_body <- function(f, cfg) {
  body <- list(summary = compose_title(f$title, f$who, f$pending))
  if (f$all_day) {
    body$start <- list(date = f$date)
    body$end   <- list(date = format(as.Date(f$end_date) + 1))  # exclusive
  } else {
    body$start <- list(dateTime = paste0(f$date, "T", f$start_time, ":00"),
                       timeZone = cfg$tz)
    body$end   <- list(dateTime = paste0(f$end_date, "T", f$end_time, ":00"),
                       timeZone = cfg$tz)
  }
  body
}

# ---- Google writes ---------------------------------------------------------

event_path     <- "calendar/v3/calendars/{calendarId}/events/{eventId}"

calendar_id <- function(cfg, name) {
  id <- cfg$calendars[[name]]
  if (is.null(id)) stop("Unknown calendar: ", name, call. = FALSE)
  id
}

event_insert <- function(google, cfg, calendar, body) {
  google("POST", events_path,
         params = list(calendarId = calendar_id(cfg, calendar)), body = body)
}

# PATCH changes only the fields sent. For one day of a repeating event,
# the id is that day's instance id, so only that day changes.
event_patch <- function(google, cfg, calendar, id, body) {
  google("PATCH", event_path,
         params = list(calendarId = calendar_id(cfg, calendar), eventId = id),
         body = body)
}

event_delete <- function(google, cfg, calendar, id) {
  google("DELETE", event_path,
         params = list(calendarId = calendar_id(cfg, calendar), eventId = id))
}

# ---- Adding, changing and deleting, with repeats ------------------------------

# A form moved to another first day, keeping its length.
shift_form <- function(f, d) {
  off <- as.Date(d) - as.Date(f$date)
  f$date <- format(as.Date(d))
  if (nzchar(f$end_date)) f$end_date <- format(as.Date(f$end_date) + off)
  f
}

# Adds an event from a form. form[["repeat"]] (see R/repeat.R) makes it a
# series or separate copies. Returns the ids Google gave.
add_event <- function(google, cfg, calendar, form) {
  f   <- clean_form(form, cfg)
  rep <- clean_repeat(form[["repeat"]], f$date)
  if (is.null(rep)) {
    return(event_insert(google, cfg, calendar, event_body(f, cfg))$id)
  }
  f <- shift_form(f, rep$first)   # weekly: first chosen weekday

  if (rep$as == "series") {
    body <- event_body(f, cfg)
    body$recurrence <- list(rrule(rep, f$all_day, cfg$tz))
    return(event_insert(google, cfg, calendar, body)$id)
  }

  dates <- repeat_dates(rep, limit = max_separate)
  ids <- character()
  for (d in as.list(dates)) {
    ev <- tryCatch(event_insert(google, cfg, calendar, event_body(shift_form(f, d), cfg)),
                   error = function(e) {
                     stop(sprintf("Added %d of %d events, then Google said: %s",
                                  length(ids), length(dates),
                                  google_message(conditionMessage(e))), call. = FALSE)
                   })
    ids <- c(ids, ev$id)
  }
  ids
}

# The series an event belongs to, or NA.
series_of <- function(con, calendar, id) {
  sid <- DBI::dbGetQuery(con,
    "SELECT recurring_id FROM events WHERE calendar = ? AND id = ?",
    params = list(calendar, id))$recurring_id
  if (length(sid)) sid else NA_character_
}

need_series <- function(con, calendar, id) {
  sid <- series_of(con, calendar, id)
  if (is.na(sid)) stop("That event isn't part of a series.", call. = FALSE)
  sid
}

# Changes one event, or with scope = "series" every event in its series.
# A whole series keeps its days; it takes the new title, people, times and
# length. It can't switch between all-day and timed.
change_event <- function(google, cfg, con, calendar, id, form, scope = "one") {
  f <- clean_form(form, cfg)
  if (!identical(scope, "series")) {
    return(event_patch(google, cfg, calendar, id, event_body(f, cfg)))
  }

  sid    <- need_series(con, calendar, id)
  master <- google("GET", event_path,
                   params = list(calendarId = calendar_id(cfg, calendar), eventId = sid))
  master_all_day <- !is.null(master[["start"]][["date"]])
  if (master_all_day != f$all_day) {
    stop("A whole series can't switch between all day and timed. Change one day instead.",
         call. = FALSE)
  }

  body <- list(summary = compose_title(f$title, f$who, f$pending))
  span <- as.integer(as.Date(f$end_date) - as.Date(f$date))
  if (f$all_day) {
    first <- as.Date(master[["start"]][["date"]])
    body$end <- list(date = format(first + span + 1))
  } else {
    # Google writes the series start in its own zone, so the first ten
    # characters are its local date.
    first <- as.Date(substr(master[["start"]][["dateTime"]], 1, 10))
    tz    <- master[["start"]][["timeZone"]] %||% cfg$tz
    body$start <- list(dateTime = paste0(format(first), "T", f$start_time, ":00"),
                       timeZone = tz)
    body$end   <- list(dateTime = paste0(format(first + span), "T", f$end_time, ":00"),
                       timeZone = tz)
  }
  event_patch(google, cfg, calendar, sid, body)
}

# Deletes one event, or with scope = "series" the whole series.
remove_event <- function(google, cfg, con, calendar, id, scope = "one") {
  target <- if (identical(scope, "series")) need_series(con, calendar, id) else id
  event_delete(google, cfg, calendar, target)
}

# Removes the "?" from an event's title, keeping everything else.
event_accept <- function(google, cfg, con, calendar, id) {
  raw <- DBI::dbGetQuery(con,
    "SELECT raw_title FROM events WHERE calendar = ? AND id = ?",
    params = list(calendar, id))$raw_title
  if (!length(raw)) stop("That event is gone. It may have been deleted.", call. = FALSE)
  event_patch(google, cfg, calendar, id,
              list(summary = sub("^\\s*\\?\\s*", "", raw)))
}

# Sets the dinner for one day: one all-day event on the dinner calendar.
# An empty title clears it.
set_dinner <- function(google, cfg, con, date, title) {
  if (!valid_date(date)) stop("Pick a date.", call. = FALSE)
  title <- trimws(title %||% "")
  a <- day_starts(as.Date(date), cfg$tz)
  have <- DBI::dbGetQuery(con, "
    SELECT id FROM events
    WHERE calendar = 'dinner' AND all_day = 1 AND start_ts = ?",
    params = list(a))$id

  if (!nzchar(title)) {
    for (id in have) event_delete(google, cfg, "dinner", id)
  } else if (length(have)) {
    event_patch(google, cfg, "dinner", have[1], list(summary = title))
    for (id in have[-1]) event_delete(google, cfg, "dinner", id)
  } else {
    event_insert(google, cfg, "dinner", list(
      summary = title,
      start   = list(date = date),
      end     = list(date = format(as.Date(date) + 1))
    ))
  }
  invisible(TRUE)
}

# R/repeat.R
#
# Repeating events. The wall page sends a repeat choice:
#
#   freq   "none", "daily", "weekly", "biweekly", "monthly_date",
#          "monthly_weekday" or "yearly"
#   days   weekly only: c("MO", "WE"); defaults to the first day's weekday
#   ends   "never", "on" (until a date) or "after" (a number of times)
#   until  "2027-06-01" when ends = "on" (inclusive)
#   count  10 when ends = "after"
#   as     "series"   one Google event with a repeat rule; later you can
#                     change one day or the whole series
#          "separate" independent copies, one per date, each edited alone
#
# A series goes to Google as an RRULE (RFC 5545), which Google expands
# into instances, each with a recurringEventId pointing at the series.
# Docs: https://developers.google.com/workspace/calendar/api/guides/recurringevents

weekday_codes <- c("SU", "MO", "TU", "WE", "TH", "FR", "SA")   # wday 0..6
week_order    <- c("MO", "TU", "WE", "TH", "FR", "SA", "SU")

wday_of <- function(d) as.POSIXlt(d)$wday
code_of <- function(d) weekday_codes[wday_of(d) + 1]

max_separate <- 100

# Checks the page's repeat choice and normalizes it. Returns NULL for no
# repeat. `date` is the event's first day; for weekly repeats it moves to
# the first chosen weekday on or after it (returned as $first).
clean_repeat <- function(r, date) {
  freq <- as.character(r$freq %||% "none")
  if (!length(r) || identical(freq, "none")) return(NULL)
  known <- c("daily", "weekly", "biweekly", "monthly_date", "monthly_weekday", "yearly")
  if (!freq %in% known) stop("Pick how often it repeats.", call. = FALSE)
  d <- as.Date(date)

  out <- list(
    freq     = switch(freq, biweekly = "weekly", monthly_date = , monthly_weekday = "monthly", freq),
    interval = if (freq == "biweekly") 2L else 1L,
    by       = if (freq == "monthly_weekday") "weekday" else "date",
    days     = character(),
    first    = d
  )

  if (out$freq == "weekly") {
    days <- toupper(as.character(unlist(r$days %||% list())))
    days <- week_order[week_order %in% days]
    if (!length(days)) days <- code_of(d)
    out$days <- days
    while (!code_of(out$first) %in% days) out$first <- out$first + 1
  }

  ends <- as.character(r$ends %||% "never")
  if (!ends %in% c("never", "on", "after")) ends <- "never"
  out$ends <- ends
  if (ends == "on") {
    u <- as.character(r$until %||% "")
    if (!valid_date(u)) stop("Pick the last day it repeats.", call. = FALSE)
    if (as.Date(u) < out$first) {
      stop("The repeat can't end before it starts.", call. = FALSE)
    }
    out$until <- as.Date(u)
  }
  if (ends == "after") {
    n <- suppressWarnings(as.integer(r$count))
    if (is.na(n) || n < 1 || n > 500) {
      stop("Pick how many times it happens (1 to 500).", call. = FALSE)
    }
    out$count <- n
  }

  out$as <- if (identical(as.character(r$as %||% ""), "separate")) "separate" else "series"
  if (out$as == "separate") {
    if (ends == "never") {
      stop("Separate events need an end: a last day or a number of times.", call. = FALSE)
    }
    n <- length(repeat_dates(out, limit = max_separate + 1))
    if (n > max_separate) {
      stop(sprintf("That makes more than %d separate events. Save it as a series, or end it sooner.",
                   max_separate), call. = FALSE)
    }
  }
  out
}

# The n-th (1-5) or last (-1) given weekday of a month, or NA.
nth_weekday <- function(year, month, wday, n) {
  first <- as.Date(sprintf("%04d-%02d-01", year, month))
  last  <- seq(first, by = "month", length.out = 2)[2] - 1
  days  <- seq(first, last, by = "day")
  hits  <- days[wday_of(days) == wday]
  if (n == -1) return(hits[length(hits)])
  if (n > length(hits)) return(as.Date(NA))
  hits[n]
}

# Dates of a repeat, first included, in order. Stops at the end the rule
# gives, at `horizon` (a Date), or after `limit` dates. A rule with no end
# stops after five years.
repeat_dates <- function(r, limit = 1000, horizon = NULL) {
  first <- r$first
  count <- r$count %||% Inf
  # A rule with no end stops after five years; a count can run longer.
  stop_at <- first + if (is.finite(count)) 366 * 200 else 5 * 366
  if (!is.null(r$until))   stop_at <- min(stop_at, r$until)
  if (!is.null(horizon))   stop_at <- min(stop_at, as.Date(horizon))
  lt <- as.POSIXlt(first)
  ym <- function(k) {
    m <- lt$mon + k
    c(lt$year + 1900 + m %/% 12, m %% 12 + 1)
  }

  out <- as.Date(character())
  if (stop_at < first) return(out)

  if (r$freq == "daily") {
    out <- seq(first, stop_at, by = r$interval)
  } else if (r$freq == "weekly") {
    week_start <- first - (wday_of(first) + 6) %% 7      # Monday
    days <- seq(week_start, stop_at, by = "day")
    keep <- days >= first & code_of(days) %in% r$days &
      (as.numeric(days - week_start) %/% 7) %% r$interval == 0
    out <- days[keep]
  } else if (r$freq == "monthly") {
    n <- ceiling(lt$mday / 7)
    if (n == 5) n <- -1
    k <- 0
    repeat {
      p <- ym(k)
      d <- if (r$by == "weekday") {
        nth_weekday(p[1], p[2], lt$wday, n)
      } else {
        as.Date(sprintf("%04d-%02d-%02d", p[1], p[2], lt$mday), optional = TRUE)
      }
      if (!is.na(d) && d > stop_at) break
      if (!is.na(d)) out <- c(out, d)
      if (length(out) >= min(count, limit)) break
      k <- k + r$interval
      if (k > 12 * 200) break
    }
  } else if (r$freq == "yearly") {
    y <- lt$year + 1900
    repeat {
      d <- as.Date(sprintf("%04d-%02d-%02d", y, lt$mon + 1, lt$mday), optional = TRUE)
      if (!is.na(d) && d > stop_at) break
      if (!is.na(d)) out <- c(out, d)
      if (length(out) >= min(count, limit) || y > lt$year + 1900 + 200) break
      y <- y + 1
    }
  }

  out <- out[out <= stop_at]
  head(out, min(count, limit))
}

# Google's recurrence line for a cleaned repeat.
rrule <- function(r, all_day, tz) {
  parts <- c(sprintf("FREQ=%s", toupper(r$freq)))
  if (r$interval > 1) parts <- c(parts, sprintf("INTERVAL=%d", r$interval))
  if (r$freq == "weekly") parts <- c(parts, paste0("BYDAY=", paste(r$days, collapse = ",")))
  if (r$freq == "monthly" && r$by == "weekday") {
    n <- ceiling(as.POSIXlt(r$first)$mday / 7)
    if (n == 5) n <- -1
    parts <- c(parts, sprintf("BYDAY=%d%s", n, code_of(r$first)))
  }
  if (r$ends == "after") parts <- c(parts, sprintf("COUNT=%d", r$count))
  if (r$ends == "on") {
    until <- if (all_day) {
      format(r$until, "%Y%m%d")
    } else {
      # The end of that day where the family lives, written in UTC.
      end_local <- as.POSIXct(paste(format(r$until), "23:59:59"), tz = tz)
      format(end_local, "%Y%m%dT%H%M%SZ", tz = "UTC")
    }
    parts <- c(parts, paste0("UNTIL=", until))
  }
  paste0("RRULE:", paste(parts, collapse = ";"))
}

# Reads back the rules rrule() writes. Used by the test fake to expand a
# series the way Google would.
parse_rrule <- function(rule, first, tz) {
  kv <- strsplit(strsplit(sub("^RRULE:", "", rule), ";", fixed = TRUE)[[1]], "=", fixed = TRUE)
  p  <- setNames(vapply(kv, `[`, "", 2), vapply(kv, `[`, "", 1))
  r <- list(freq = tolower(p[["FREQ"]]),
            interval = if ("INTERVAL" %in% names(p)) as.integer(p[["INTERVAL"]]) else 1L,
            by = "date", days = character(), first = as.Date(first), ends = "never")
  if ("BYDAY" %in% names(p)) {
    if (r$freq == "weekly") r$days <- strsplit(p[["BYDAY"]], ",", fixed = TRUE)[[1]]
    if (r$freq == "monthly") r$by <- "weekday"
  }
  if ("COUNT" %in% names(p)) { r$ends <- "after"; r$count <- as.integer(p[["COUNT"]]) }
  if ("UNTIL" %in% names(p)) {
    u <- p[["UNTIL"]]
    r$ends <- "on"
    r$until <- if (nchar(u) == 8) {
      as.Date(u, format = "%Y%m%d")
    } else {
      as.Date(as.POSIXct(u, format = "%Y%m%dT%H%M%SZ", tz = "UTC"), tz = tz)
    }
  }
  r
}

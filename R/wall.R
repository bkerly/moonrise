# R/wall.R
#
# Builds what the wall page shows. The page itself only draws; the date
# math, colors and labels happen here, where they can be tested.
#
# Color rules (from the plan):
#   - children decide the color: one child = that child's color, even with
#     an adult; two or more children = the "children" color
#   - one adult alone = that adult's color
#   - F, or every adult and no children = the "family" color
#   - no initials (for example a fresh import) = the "none" color

okabe_ito <- c("#0072B2", "#D55E00", "#009E73", "#CC79A7", "#E69F00",
               "#56B4E9", "#F0E442")

# One row per family member: initial, name, color, adult.
wall_people <- function(cfg) {
  init <- names(cfg$family)
  if (!length(init)) {
    return(data.frame(initial = character(), name = character(),
                      color = character(), adult = logical()))
  }
  name  <- vapply(init, function(i) as.character(cfg$family[[i]]), "")
  color <- vapply(seq_along(init), function(k) {
    cfg$colors[[init[k]]] %||% okabe_ito[(k - 1) %% length(okabe_ito) + 1]
  }, "")
  data.frame(initial = init, name = unname(name), color = color,
             adult = init %in% cfg$adults, stringsAsFactors = FALSE)
}

# `who` is a vector like c("V N", "K", "", "F").
event_colors <- function(who, cfg, people = wall_people(cfg)) {
  g <- cfg$group_colors
  vapply(strsplit(who, " ", fixed = TRUE), function(w) {
    w <- w[nzchar(w)]
    if (!length(w)) return(g$none)
    if ("F" %in% w) return(g$family)
    p      <- people[people$initial %in% w, , drop = FALSE]
    kids   <- p[!p$adult, , drop = FALSE]
    adults <- p[p$adult, , drop = FALSE]
    if (nrow(kids) >= 2) return(g$children)
    if (nrow(kids) == 1) return(kids$color)
    if (nrow(adults) == 1) return(adults$color)
    if (nrow(adults) >= 2) return(g$family)
    g$none
  }, "")
}

# "4:00 PM"
clock_label <- function(ts, tz) {
  x <- format(as.POSIXct(ts, origin = "1970-01-01", tz = tz), "%I:%M %p")
  sub("^0", "", x)
}

# Midnight at the start of each date, in the calendar's time zone. Built
# from the date text so DST days are 23 or 25 hours long, as they should be.
day_starts <- function(dates, tz) {
  as.numeric(as.POSIXct(format(dates), format = "%Y-%m-%d", tz = tz))
}

# Version the page polls. Goes up whenever any calendar's contents change.
store_version <- function(con) {
  st <- DBI::dbGetQuery(con, "
    SELECT COALESCE(SUM(version), 0) AS version,
           MAX(last_check)           AS last_check,
           SUM(last_error IS NOT NULL) AS errors
    FROM sync_state")
  list(version    = as.integer(st$version),
       last_check = if (is.na(st$last_check)) NULL else st$last_check,
       errors     = as.integer(st$errors %||% 0))
}

# The week view: `days` days from `start` (a Date), events bucketed by
# local day. Multi-day events appear on every day they cover.
week_payload <- function(con, cfg, start = NULL, days = 7, now = Sys.time()) {
  tz    <- cfg$tz
  today <- as.Date(now, tz = tz)
  if (is.null(start)) start <- today
  dates  <- start + 0:(days - 1)
  bounds <- day_starts(c(dates, dates[days] + 1), tz)

  ev <- store_events_between(con, bounds[1], bounds[days + 1])
  for (col in c("title", "who", "location")) ev[[col]][is.na(ev[[col]])] <- ""
  people   <- wall_people(cfg)
  ev$color <- event_colors(ev$who, cfg, people)
  now_ts   <- as.numeric(now)

  day_list <- lapply(seq_len(days), function(k) {
    a <- bounds[k]
    b <- bounds[k + 1]
    on <- ev[ev$start_ts < b & (ev$end_ts > a | ev$start_ts >= a), , drop = FALSE]

    item <- function(r) {
      cont <- r$all_day == 0 && r$start_ts < a
      list(
        id       = r$id,
        title    = r$title,
        who      = r$who,
        color    = r$color,
        pending  = r$pending == 1,
        all_day  = r$all_day == 1,
        time     = if (r$all_day == 1) "" else if (cont) "cont." else
                     clock_label(r$start_ts, tz),
        location = r$location,
        past     = r$end_ts <= now_ts
      )
    }
    rows <- function(d) lapply(seq_len(nrow(d)), function(i) item(d[i, ]))

    dinner <- on[on$calendar == "dinner", , drop = FALSE]
    fam    <- on[on$calendar != "dinner", , drop = FALSE]
    fam    <- fam[order(-fam$all_day, fam$start_ts, fam$title), , drop = FALSE]

    list(
      date    = format(dates[k]),
      weekday = format(dates[k], "%a"),
      day     = as.integer(format(dates[k], "%d")),
      month   = format(dates[k], "%b"),
      today   = dates[k] == today,
      dinner  = as.list(dinner$title),
      events  = rows(fam)
    )
  })

  list(
    today   = format(today),
    heading = sub(" 0", " ", format(today, "%A, %B %d")),
    start   = format(start),
    version = store_version(con)$version,
    people  = lapply(seq_len(nrow(people)), function(i) as.list(people[i, ])),
    groups  = cfg$group_colors,
    days    = day_list
  )
}

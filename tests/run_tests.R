# tests/run_tests.R
#
# Offline tests. A fake Google stands in for the real API, so no sign-in
# or network is needed.
#
# From the repo folder:   Rscript tests/run_tests.R

for (f in list.files("R", "\\.R$", full.names = TRUE)) source(f)

passed <- 0
failed <- 0
test <- function(name, code) {
  ok <- tryCatch({ force(code); TRUE }, error = function(e) {
    cat(sprintf("FAIL  %s\n      %s\n", name, conditionMessage(e)))
    FALSE
  })
  if (ok) { passed <<- passed + 1; cat(sprintf("PASS  %s\n", name)) }
  else failed <<- failed + 1
}
expect_equal <- function(got, want) {
  if (!isTRUE(all.equal(got, want, check.attributes = FALSE))) {
    stop(sprintf("got %s, want %s",
                 paste(deparse(got), collapse = ""),
                 paste(deparse(want), collapse = "")), call. = FALSE)
  }
}

# ---- Test config -----------------------------------------------------------

tmp <- tempfile("moonrise-test-")
dir.create(tmp)
cfg_path <- file.path(tmp, "config.json")
writeLines('{
  "account": "test@gmail.com",
  "calendars": { "family": "fam@group", "dinner": "din@group" },
  "allowed_senders": ["Someone@Gmail.com"],
  "family": { "B": "b", "K": "k", "V": "v", "N": "n", "A": "a" },
  "sync": { "days_ahead": 30 }
}', cfg_path)
cfg <- moonrise_config(cfg_path)
cfg$data_dir <- file.path(tmp, "data")

test("config fills defaults and keeps overrides", {
  expect_equal(cfg$sync$every_seconds, 60)
  expect_equal(cfg$sync$days_back, 31)
  expect_equal(cfg$sync$days_ahead, 30)
  expect_equal(cfg$allowed_senders, "someone@gmail.com")
  expect_equal(names(cfg$family), c("B", "K", "V", "N", "A"))
})

# ---- Titles ----------------------------------------------------------------

test("titles: initials, pending, plain", {
  x <- c("V N - Swim Lessons", "? K - Dentist", "F - Zoo day",
         "Pick up dry cleaning", "? Moonrise test - delete me",
         "BBQ - park", "Bake sale - school", "V,N: Soccer",
         # Built from JSON, as Google's data arrives, so it is marked UTF-8
         # even when R runs in a plain C locale.
         jsonlite::fromJSON('"B & K \\u2013 Date night"'), "VN - Piano", NA, "?   ",
         "N V V - Recital")
  p <- parse_titles(x, names(cfg$family))
  expect_equal(p$who, c("V N", "K", "F", "", "", "", "", "V N", "B K",
                        "V N", "", "", "N V"))
  expect_equal(p$title, c("Swim Lessons", "Dentist", "Zoo day",
                          "Pick up dry cleaning", "Moonrise test - delete me",
                          "BBQ - park", "Bake sale - school", "Soccer",
                          "Date night", "Piano", "", "", "Recital"))
  expect_equal(p$pending, c(FALSE, TRUE, FALSE, FALSE, TRUE, FALSE, FALSE,
                            FALSE, FALSE, FALSE, FALSE, TRUE, FALSE))
})

test("titles: empty input", {
  expect_equal(nrow(parse_titles(character(0), "B")), 0)
})

# ---- Times -----------------------------------------------------------------

test("rfc3339 with offset, Z and fractions", {
  want <- as.numeric(as.POSIXct("2026-10-30 17:34:59", tz = "UTC"))
  expect_equal(parse_rfc3339("2026-10-30T11:34:59-06:00"), want)
  expect_equal(parse_rfc3339("2026-10-30T17:34:59Z"), want)
  expect_equal(parse_rfc3339("2026-10-30T17:34:59.000Z"), want)
})

test("event rows: timed, all-day, cancelled, untitled", {
  items <- list(
    list(id = "a", status = "confirmed", summary = "V - Swim",
         start = list(dateTime = "2026-11-02T16:00:00-07:00"),
         end   = list(dateTime = "2026-11-02T17:00:00-07:00")),
    list(id = "b", status = "confirmed", summary = "F - Thanksgiving",
         start = list(date = "2026-11-26"), end = list(date = "2026-11-27"),
         recurringEventId = "r1"),
    list(id = "c", status = "cancelled"),
    list(id = "d", status = "confirmed",
         start = list(dateTime = "2026-11-03T08:00:00-07:00"),
         end   = list(dateTime = "2026-11-03T09:00:00-07:00"))
  )
  r <- event_rows(items, cfg)
  expect_equal(r$id, c("a", "b", "d"))
  expect_equal(r$all_day, c(0L, 1L, 0L))
  expect_equal(r$who, c("V", "F", ""))
  expect_equal(r$end_ts[1] - r$start_ts[1], 3600)
  expect_equal(r$start_ts[2],
               as.numeric(as.POSIXct("2026-11-26", tz = "America/Denver")))
  expect_equal(r$end_ts[2] - r$start_ts[2], 86400)
  expect_equal(r$recurring_id, c(NA, "r1", NA))
  expect_equal(r$raw_title[3], NA_character_)
})

test("event rows: no items", {
  expect_equal(nrow(event_rows(list(), cfg)), 0)
})

# ---- Fake Google -----------------------------------------------------------

# Holds per-calendar events and a list of pending changes. Records every
# call so tests can count them.
fake_google <- function() {
  env <- new.env()
  env$events  <- list(fam = list(), din = list())
  env$changes <- list(fam = 0, din = 0)
  env$token   <- list(fam = 1, din = 1)
  env$calls   <- list()
  env$fail_window <- FALSE
  env$expire  <- FALSE
  env$page_size <- 2

  key <- function(id) sub("@.*", "", id)

  env$google <- function(method, path, params = list(), body = NULL) {
    env$calls[[length(env$calls) + 1]] <- params
    k <- key(params$calendarId)
    if (!is.null(params$timeMin)) {
      if (env$fail_window) stop("network down")
      # Window listing with paging.
      all   <- env$events[[k]]
      start <- if (is.null(params$pageToken)) 1 else as.integer(params$pageToken)
      end   <- min(length(all), start + env$page_size - 1)
      res   <- list(items = if (length(all)) all[start:end] else list())
      if (end < length(all)) res$nextPageToken <- as.character(end + 1)
      return(res)
    }
    # Change check.
    if (!is.null(params$syncToken)) {
      if (env$expire) { env$expire <- FALSE; stop(moonrise_gone()) }
      n <- env$changes[[k]]
      env$changes[[k]] <- 0
    } else {
      n <- length(env$events[[k]])   # full listing
    }
    env$token[[k]] <- env$token[[k]] + 1
    list(items = rep(list(list(id = "x")), n),
         nextSyncToken = paste0(k, "-", env$token[[k]]))
  }
  env
}

ev <- function(id, title, day, hour = 9) {
  s <- sprintf("2026-%sT%02d:00:00-06:00", day, hour)
  e <- sprintf("2026-%sT%02d:00:00-06:00", day, hour + 1)
  list(id = id, status = "confirmed", summary = title,
       start = list(dateTime = s), end = list(dateTime = e))
}

window_calls <- function(fg) sum(vapply(fg$calls, function(p) !is.null(p$timeMin), TRUE))

# ---- Sync flow -------------------------------------------------------------

con <- store_open(cfg)
fg  <- fake_google()
t0  <- as.POSIXct("2026-11-01 08:00:00", tz = "America/Denver")
fg$events$fam <- list(ev("e1", "V - Swim", "11-02"), ev("e2", "K - Dentist", "11-03"),
                      ev("e3", "F - Zoo", "11-04"))
fg$events$din <- list(list(id = "d1", status = "confirmed", summary = "Tacos",
                           start = list(date = "2026-11-02"),
                           end = list(date = "2026-11-03")))
state <- function(cal) store_state(con, cal)

test("first pass stores events and tokens", {
  out <- capture.output(sync_all(fg$google, con, cfg, now = t0))
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT * FROM events")), 4)
  expect_equal(state("family")$version, 1)
  expect_equal(state("family")$sync_token, "fam-2")
  expect_equal(state("dinner")$sync_token, "din-2")
  # 3 events at 2 per page = 2 window pages for family, 1 for dinner.
  expect_equal(window_calls(fg), 3)
  stopifnot(any(grepl("family: first sync; 3 events in window, updated", out)))
})

test("quiet pass makes no window call and logs nothing", {
  fg$calls <- list()
  out <- capture.output(sync_all(fg$google, con, cfg, now = t0 + 60))
  expect_equal(window_calls(fg), 0)
  expect_equal(length(fg$calls), 2)
  expect_equal(length(out), 0)
  expect_equal(state("family")$version, 1)
})

test("a change triggers a refresh and bumps the version", {
  fg$events$fam[[2]]$summary <- "? K - Dentist moved"
  fg$changes$fam <- 1
  fg$calls <- list()
  out <- capture.output(sync_all(fg$google, con, cfg, now = t0 + 120))
  expect_equal(window_calls(fg), 2)        # family only, 2 pages
  expect_equal(state("family")$version, 2)
  expect_equal(state("dinner")$version, 1)
  e2 <- DBI::dbGetQuery(con, "SELECT * FROM events WHERE id = 'e2'")
  expect_equal(e2$pending, 1)
  expect_equal(e2$title, "Dentist moved")
  stopifnot(any(grepl("family: 1 change\\(s\\)", out)))
})

test("a change with identical window keeps the version", {
  fg$changes$fam <- 1
  capture.output(sync_all(fg$google, con, cfg, now = t0 + 180))
  expect_equal(state("family")$version, 2)
})

test("deleted event disappears", {
  fg$events$fam <- fg$events$fam[-3]
  fg$changes$fam <- 1
  capture.output(sync_all(fg$google, con, cfg, now = t0 + 240))
  ids <- DBI::dbGetQuery(con, "SELECT id FROM events WHERE calendar = 'family'")$id
  expect_equal(sort(ids), c("e1", "e2"))
  expect_equal(state("family")$version, 3)
})

test("hourly refresh runs with no changes", {
  fg$calls <- list()
  out <- capture.output(sync_all(fg$google, con, cfg, now = t0 + 240 + 3600))
  expect_equal(window_calls(fg), 2)        # family 1 page + dinner 1 page
  stopifnot(any(grepl("scheduled refresh", out)))
})

test("expired token starts over", {
  fg$expire <- TRUE
  out <- capture.output(sync_all(fg$google, con, cfg, now = t0 + 4000))
  stopifnot(any(grepl("family: sync token expired", out)))
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT * FROM events WHERE calendar = 'family'")), 2)
})

test("failed refresh keeps the old token and data, logs once, recovers", {
  tok_before <- state("family")$sync_token
  fg$events$fam <- c(fg$events$fam, list(ev("e4", "N - Recital", "11-05")))
  fg$changes$fam <- 1
  fg$fail_window <- TRUE
  out1 <- capture.output(sync_all(fg$google, con, cfg, now = t0 + 4100))
  expect_equal(state("family")$sync_token, tok_before)
  expect_equal(state("family")$last_error, "network down")
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT * FROM events WHERE calendar = 'family'")), 2)
  stopifnot(any(grepl("family: error: network down", out1)))

  # Same error again: not logged twice. The fake already cleared its change
  # count, so give it one again, as the real token would.
  fg$changes$fam <- 1
  out2 <- capture.output(sync_all(fg$google, con, cfg, now = t0 + 4160))
  stopifnot(!any(grepl("error", out2)))

  fg$fail_window <- FALSE
  fg$changes$fam <- 1
  out3 <- capture.output(sync_all(fg$google, con, cfg, now = t0 + 4220))
  stopifnot(any(grepl("family: working again", out3)))
  expect_equal(state("family")$last_error, NA_character_)
  ids <- DBI::dbGetQuery(con, "SELECT id FROM events WHERE calendar = 'family'")$id
  expect_equal(sort(ids), c("e1", "e2", "e4"))
})

test("events_between finds overlapping events across calendars", {
  from <- as.POSIXct("2026-11-02 00:00", tz = "America/Denver")
  to   <- as.POSIXct("2026-11-03 00:00", tz = "America/Denver")
  got  <- store_events_between(con, from, to)
  expect_equal(sort(got$id), c("d1", "e1"))
})

test("store survives reopening", {
  DBI::dbDisconnect(con)
  con <<- store_open(cfg)
  expect_equal(state("family")$version, 4)
})

DBI::dbDisconnect(con)

# ---- Wall: colors ----------------------------------------------------------

wcfg <- cfg
wcfg$adults <- c("B", "K")
wcfg$colors <- list(V = "#123456")

test("people get config colors, then Okabe-Ito in order", {
  p <- wall_people(wcfg)
  expect_equal(p$initial, c("B", "K", "V", "N", "A"))
  expect_equal(p$color, c("#0072B2", "#D55E00", "#123456", "#CC79A7", "#E69F00"))
  expect_equal(p$adult, c(TRUE, TRUE, FALSE, FALSE, FALSE))
})

test("color rules: children decide", {
  g <- wcfg$group_colors
  got <- event_colors(c("V", "V B", "V N", "N A K", "B", "B K", "F", "F V", "", "Q"), wcfg)
  expect_equal(got, c("#123456", "#123456", g$children, g$children,
                      "#0072B2", g$family, g$family, g$family, g$none, g$none))
})

# ---- Wall: week ------------------------------------------------------------

wcfg$data_dir <- file.path(tmp, "wall")
wcon <- store_open(wcfg)
tz   <- wcfg$tz
lt   <- function(s) format(as.POSIXct(s, tz = tz), "%Y-%m-%dT%H:%M:%S%z")
item <- function(id, title, from, to) {
  list(id = id, status = "confirmed", summary = title,
       start = list(dateTime = lt(from)), end = list(dateTime = lt(to)))
}
day_item <- function(id, title, from, to) {
  list(id = id, status = "confirmed", summary = title,
       start = list(date = from), end = list(date = to))
}
store_replace_events(wcon, "family", event_rows(list(
  item("a", "V - Swim", "2026-10-31 08:00", "2026-10-31 09:00"),
  item("b", "B K - Late party", "2026-10-31 22:00", "2026-11-01 01:00"),
  day_item("c", "F - Grandma", "2026-11-01", "2026-11-03"),
  item("d", "N - After DST", "2026-11-01 15:30", "2026-11-01 16:00"),
  item("e", "? Field trip", "2026-11-02 09:00", "2026-11-02 12:00"),
  item("z", "Outside week", "2026-11-12 09:00", "2026-11-12 10:00")
), wcfg))
store_replace_events(wcon, "dinner", event_rows(list(
  day_item("d1", "Tacos", "2026-10-31", "2026-11-01")
), wcfg))

wk <- week_payload(wcon, wcfg, start = as.Date("2026-10-31"),
                   now = as.POSIXct("2026-10-31 12:00", tz = tz))
ids <- function(k) vapply(wk$days[[k]]$events, `[[`, "", "id")

test("week: seven days, today flagged, heading", {
  expect_equal(length(wk$days), 7)
  expect_equal(wk$days[[1]]$date, "2026-10-31")
  expect_equal(wk$days[[1]]$today, TRUE)
  expect_equal(wk$days[[2]]$today, FALSE)
  expect_equal(wk$heading, "Saturday, October 31")
})

test("week: events land on the right days", {
  expect_equal(ids(1), c("a", "b"))
  expect_equal(ids(2), c("c", "b", "d"))   # all-day first, then by time
  expect_equal(ids(3), c("c", "e"))
  expect_equal(ids(4), character())
  expect_equal(wk$days[[1]]$dinner, list("Tacos"))
  expect_equal(wk$days[[2]]$dinner, list())
})

test("week: labels, past, pending, colors", {
  d1 <- wk$days[[1]]$events
  d2 <- wk$days[[2]]$events
  expect_equal(d1[[1]]$time, "8:00 AM")
  expect_equal(d1[[1]]$past, TRUE)
  expect_equal(d1[[2]]$past, FALSE)
  expect_equal(d1[[2]]$color, wcfg$group_colors$family)
  expect_equal(d2[[2]]$time, "cont.")        # party runs past midnight
  expect_equal(d2[[3]]$time, "3:30 PM")      # day after DST ends
  expect_equal(d2[[1]]$time, "")
  e <- wk$days[[3]]$events[[2]]
  expect_equal(e$pending, TRUE)
  expect_equal(e$color, wcfg$group_colors$none)
})

test("week: DST day is 25 hours", {
  b <- day_starts(as.Date(c("2026-11-01", "2026-11-02")), tz)
  expect_equal(diff(b), 25 * 3600)
})

test("week: version counts all calendars", {
  expect_equal(wk$version, 2)
})

DBI::dbDisconnect(wcon)
unlink(tmp, recursive = TRUE)

cat(sprintf("\n%d passed, %d failed\n", passed, failed))
if (failed) quit(status = 1)

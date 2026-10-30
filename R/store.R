# R/store.R
#
# Local SQLite copy of the calendars, read by the wall page and phone app.
# The file lives in cfg$data_dir (default ~/.local/share/moonrise).
#
# events      one row per event instance (repeating events are expanded)
# sync_state  one row per calendar: sync token, last check, last refresh,
#             and a version number that goes up whenever the events change

store_open <- function(cfg) {
  dir.create(cfg$data_dir, recursive = TRUE, showWarnings = FALSE)
  con <- DBI::dbConnect(RSQLite::SQLite(),
                        file.path(cfg$data_dir, "moonrise.sqlite"))
  # WAL lets the web server read while the sync loop writes.
  DBI::dbExecute(con, "PRAGMA journal_mode = WAL")
  DBI::dbExecute(con, "PRAGMA busy_timeout = 5000")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS events (
      calendar     TEXT NOT NULL,
      id           TEXT NOT NULL,
      raw_title    TEXT,
      title        TEXT,
      who          TEXT,
      pending      INTEGER,
      all_day      INTEGER,
      start        TEXT,
      end          TEXT,
      start_ts     REAL,
      end_ts       REAL,
      location     TEXT,
      description  TEXT,
      recurring_id TEXT,
      updated      TEXT,
      html_link    TEXT,
      PRIMARY KEY (calendar, id)
    )")
  DBI::dbExecute(con, "
    CREATE INDEX IF NOT EXISTS events_by_time ON events (start_ts, end_ts)")
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sync_state (
      calendar      TEXT PRIMARY KEY,
      sync_token    TEXT,
      last_check    REAL,
      last_refresh  REAL,
      data_hash     TEXT,
      version       INTEGER NOT NULL DEFAULT 0,
      last_error    TEXT
    )")
  # One row per email the importer has looked at, so it never reads the
  # same one twice.
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS imports (
      message_id  TEXT PRIMARY KEY,
      received    REAL,
      sender      TEXT,
      subject     TEXT,
      status      TEXT,
      events      INTEGER,
      event_ids   TEXT,
      note        TEXT,
      attempts    INTEGER NOT NULL DEFAULT 0,
      processed   REAL
    )")
  con
}

store_state <- function(con, calendar) {
  st <- DBI::dbGetQuery(con, "SELECT * FROM sync_state WHERE calendar = ?",
                        params = list(calendar))
  if (nrow(st)) return(as.list(st[1, ]))
  DBI::dbExecute(con, "INSERT INTO sync_state (calendar) VALUES (?)",
                 params = list(calendar))
  store_state(con, calendar)
}

store_set_state <- function(con, calendar, ...) {
  vals <- list(...)
  sets <- paste(sprintf("%s = ?", names(vals)), collapse = ", ")
  DBI::dbExecute(con, sprintf("UPDATE sync_state SET %s WHERE calendar = ?",
                              sets),
                 params = unname(c(vals, list(calendar))))
  invisible(TRUE)
}

# Replaces every event for one calendar in a single transaction, so readers
# never see a half-written calendar. Bumps the version only when the
# contents differ from last time. Returns TRUE if anything changed.
store_replace_events <- function(con, calendar, rows) {
  rows$calendar <- rep(calendar, nrow(rows))
  rows <- rows[order(rows$start_ts, rows$id), , drop = FALSE]
  hash <- rlang::hash(rows)
  st   <- store_state(con, calendar)
  if (identical(st$data_hash, hash)) return(invisible(FALSE))

  DBI::dbWithTransaction(con, {
    DBI::dbExecute(con, "DELETE FROM events WHERE calendar = ?",
                   params = list(calendar))
    if (nrow(rows)) DBI::dbAppendTable(con, "events", rows)
    DBI::dbExecute(con, "
      UPDATE sync_state SET data_hash = ?, version = version + 1
      WHERE calendar = ?", params = list(hash, calendar))
  })
  invisible(TRUE)
}

# Events overlapping [from, to), for any calendar.
store_events_between <- function(con, from, to) {
  DBI::dbGetQuery(con, "
    SELECT * FROM events
    WHERE start_ts < ? AND end_ts > ?
    ORDER BY start_ts, calendar, title",
    params = list(as.numeric(to), as.numeric(from)))
}

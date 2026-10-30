# scripts/sync_once.R
#
# Runs one sync pass and prints the next 7 days from the local store.
# Use it to test sync without leaving a loop running.
#
# From the repo folder, in R:   source("scripts/sync_once.R")
# or in a terminal:             Rscript scripts/sync_once.R

for (f in list.files("R", "\\.R$", full.names = TRUE)) source(f)

cfg    <- moonrise_config()
google <- moonrise_google(cfg)
con    <- store_open(cfg)

sync_all(google, con, cfg)

now  <- Sys.time()
week <- store_events_between(con, now, now + 7 * 24 * 3600)

cat(sprintf("\nNext 7 days (%d events):\n", nrow(week)))
if (nrow(week)) {
  when <- ifelse(
    week$all_day == 1,
    format(as.POSIXct(week$start_ts, origin = "1970-01-01", tz = cfg$tz),
           "%a %b %d  all day"),
    format(as.POSIXct(week$start_ts, origin = "1970-01-01", tz = cfg$tz),
           "%a %b %d  %H:%M")
  )
  print(data.frame(
    when     = when,
    calendar = week$calendar,
    who      = week$who,
    title    = paste0(ifelse(week$pending == 1, "? ", ""), week$title)
  ), row.names = FALSE)
}

state <- DBI::dbGetQuery(con, "SELECT calendar, version, last_error FROM sync_state")
cat("\nStore:", file.path(cfg$data_dir, "moonrise.sqlite"), "\n")
print(state, row.names = FALSE)

DBI::dbDisconnect(con)

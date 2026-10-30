# scripts/sync_loop.R
#
# Keeps the local store in step with Google Calendar until stopped.
# Logs only when something happens (first sync, changes, hourly refresh,
# errors), not on every quiet check.
#
# In a terminal, from the repo folder:
#   Rscript scripts/sync_loop.R
# Stop with Ctrl-C.
#
# Sign in once with scripts/smoke_test.R first; this script can't open a
# browser when run with Rscript.

for (f in list.files("R", "\\.R$", full.names = TRUE)) source(f)

cfg    <- moonrise_config()
google <- moonrise_google(cfg)
con    <- store_open(cfg)

moonrise_log("sync loop started: %s, every %d s",
             paste(names(cfg$calendars), collapse = " + "),
             as.integer(cfg$sync$every_seconds))

start_sync_loop(google, con, cfg)

# Run the `later` event loop. A plumber server will do this itself once it
# shares the process.
while (TRUE) later::run_now(timeoutSecs = Inf)

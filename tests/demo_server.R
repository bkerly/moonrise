# tests/demo_server.R
#
# Serves the wall page with made-up events and no Google sign-in, for
# trying layout changes. Uses a throwaway store in a temp folder.
#
# From the repo folder:   Rscript tests/demo_server.R [port]
# Then open http://localhost:8080/

for (f in list.files("R", "\\.R$", full.names = TRUE)) source(f)

args <- commandArgs(TRUE)
port <- if (length(args)) as.integer(args[1]) else 8080L

tmp <- tempfile("moonrise-demo-")
dir.create(tmp)
cfg_path <- file.path(tmp, "config.json")
writeLines('{
  "account": "demo@gmail.com",
  "calendars": { "family": "fam@group", "dinner": "din@group" },
  "allowed_senders": ["demo@gmail.com"],
  "family": { "B": "Parent B", "K": "Parent K", "V": "Kid V",
              "N": "Kid N", "A": "Kid A" },
  "adults": ["B", "K"]
}', cfg_path)
cfg <- moonrise_config(cfg_path)
cfg$data_dir <- file.path(tmp, "data")
con <- store_open(cfg)

# ---- Made-up week ----------------------------------------------------------

tz    <- cfg$tz
today <- as.Date(Sys.time(), tz = tz)
at <- function(day, hm) {
  format(as.POSIXct(paste(format(today + day), hm), tz = tz),
         "%Y-%m-%dT%H:%M:%S%z")
}
timed <- function(id, title, day, from, to) {
  list(id = id, status = "confirmed", summary = title,
       start = list(dateTime = at(day, from)), end = list(dateTime = at(day, to)))
}
allday <- function(id, title, day, days = 1) {
  list(id = id, status = "confirmed", summary = title,
       start = list(date = format(today + day)),
       end = list(date = format(today + day + days)))
}

family <- list(
  timed("1", "V N - Swim Lessons", 0, "08:00", "09:00"),
  timed("2", "K - Dentist", 0, "10:30", "11:15"),
  timed("3", "A - Preschool pickup", 0, "15:00", "15:15"),
  timed("4", "? Book fair volunteer shift", 0, "17:30", "18:30"),
  allday("5", "F - Grandma visiting", 1, 3),
  timed("6", "V - Soccer practice", 1, "16:00", "17:15"),
  timed("7", "B - Hyrox class", 2, "06:00", "07:00"),
  timed("8", "N - Piano", 2, "15:30", "16:00"),
  timed("9", "B K - Date night", 3, "19:00", "22:00"),
  timed("10", "? V - Birthday party at the climbing gym", 4, "13:00", "15:00"),
  timed("11", "F - Pumpkin patch", 5, "10:00", "12:00"),
  timed("12", "N A - Library story time", 5, "10:30", "11:15"),
  timed("13", "Trash night", 6, "19:00", "19:15"),
  timed("14", "K - Long run", 6, "07:00", "08:30")
)
dinner <- list(
  allday("d0", "Tacos", 0), allday("d1", "Leftovers", 1),
  allday("d2", "Sheet-pan chicken and potatoes", 2),
  allday("d4", "Pizza night", 4), allday("d5", "Chili", 5)
)
store_replace_events(con, "family", event_rows(family, cfg))
store_replace_events(con, "dinner", event_rows(dinner, cfg))
for (cal in c("family", "dinner")) {
  store_set_state(con, cal, last_check = as.numeric(Sys.time()))
}

cat(sprintf("Demo wall page: http://localhost:%d/\n", port))
plumber::pr_run(moonrise_router(cfg, con), host = "127.0.0.1", port = port,
                docs = FALSE, quiet = TRUE)

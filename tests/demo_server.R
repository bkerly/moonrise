# tests/demo_server.R
#
# Serves the wall page with made-up events and a fake Google, so you can
# try the page, including adding and editing events, without signing in.
# A sample forwarded email is "imported" a few seconds after start, with a
# canned model answer, so a Review item appears. Nothing touches your real
# calendars, and everything is gone when you stop it.
#
# From the repo folder:   Rscript tests/demo_server.R [port]
# Then open http://localhost:8080/

for (f in list.files("R", "\\.R$", full.names = TRUE)) source(f)
source("tests/fake_google.R")

args <- commandArgs(TRUE)
port <- if (length(args)) as.integer(args[1]) else 8080L

tmp <- tempfile("moonrise-demo-")
dir.create(tmp)
cfg_path <- file.path(tmp, "config.json")
writeLines('{
  "account": "demo@gmail.com",
  "calendars": { "family": "fam@group", "dinner": "din@group" },
  "allowed_senders": ["parent@demo.org"],
  "family": { "B": "Parent B", "K": "Parent K", "V": "Kid V",
              "N": "Kid N", "A": "Kid A" },
  "adults": ["B", "K"],
  "import": { "every_seconds": 5 }
}', cfg_path)
cfg <- moonrise_config(cfg_path)
cfg$data_dir <- file.path(tmp, "data")
con <- store_open(cfg)
fk  <- fake_google(unlist(cfg$calendars))

# ---- Made-up week ----------------------------------------------------------

tz    <- cfg$tz
today <- as.Date(Sys.time(), tz = tz)
at <- function(day, hm) {
  list(dateTime = paste0(format(today + day), "T", hm, ":00"), timeZone = tz)
}
timed <- function(title, day, from, to) {
  invisible(fk$google("POST", events_path, params = list(calendarId = "fam@group"),
            body = list(summary = title, start = at(day, from), end = at(day, to))))
}
allday <- function(cal, title, day, days = 1) {
  invisible(fk$google("POST", events_path, params = list(calendarId = cal),
            body = list(summary = title, start = list(date = format(today + day)),
                        end = list(date = format(today + day + days)))))
}

timed("V N - Swim Lessons", 0, "08:00", "09:00")
timed("K - Dentist", 0, "10:30", "11:15")
timed("A - Preschool pickup", 0, "15:00", "15:15")
allday("fam@group", "F - Grandma visiting", 1, 3)
invisible(add_event(fk$google, cfg, "family", list(
  title = "Soccer practice", who = list("V"), date = format(today + 1),
  start_time = "16:00", end_time = "17:15",
  `repeat` = list(freq = "weekly", days = list(code_of(today + 1), code_of(today + 4)),
                  ends = "after", count = 12, as = "series"))))
timed("B - Hyrox class", 2, "06:00", "07:00")
timed("N - Piano", 2, "15:30", "16:00")
timed("B K - Date night", 3, "19:00", "22:00")
timed("F - Pumpkin patch", 5, "10:00", "12:00")
timed("N A - Library story time", 5, "10:30", "11:15")
timed("Trash night", 6, "19:00", "19:15")
timed("K - Long run", 6, "07:00", "08:30")
for (d in c(0, 1, 2, 4, 5)) {
  allday("din@group", c("Tacos", "Leftovers", "Sheet-pan chicken", "", "Pizza night",
                        "Chili")[d + 1], d)
}

# ---- A forwarded email and a canned model answer ---------------------------

party_day <- today + 4
fk$add_email(fake_email(
  "Parent <parent@demo.org>", "Fwd: Birthday party!",
  text = sprintf("You're invited to Maya's birthday at the climbing gym, %s from 1 to 3.",
                 format(party_day, "%A, %B %d")),
  sent = Sys.time()))
demo_chat <- function(prompt, schema, opts) {
  Sys.sleep(2)   # pretend to think
  jsonlite::toJSON(list(events = list(list(
    title = "Maya's birthday party", date = format(party_day),
    start_time = "13:00", end_time = "15:00", who = list("V"),
    weekday = format(party_day, "%A"), quote = "climbing gym"))), auto_unbox = TRUE)
}

start_sync_loop(fk$google, con, cfg)
start_import_loop(fk$google, con, cfg, runner = inline_runner(demo_chat))

cat(sprintf("Demo wall page: http://localhost:%d/\n", port))
plumber::pr_run(moonrise_router(cfg, con, fk$google), host = "127.0.0.1",
                port = port, docs = FALSE, quiet = TRUE)

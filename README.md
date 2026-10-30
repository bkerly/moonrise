# Moonrise

A home-built family wall calendar: a small R server, an old Android tablet
on the wall, and a phone app. It reads and writes a shared Google Calendar
and adds events from forwarded emails.

The homepage and privacy policy (`index.html`, `privacy.html`) are served
by GitHub Pages for the Google sign-in screen.

## Layout

```
R/config.R             reads the private config (and sync defaults)
R/google.R             Google sign-in and request helper
R/titles.R             reads initials and "?" from event titles
R/store.R              local SQLite copy of the calendars
R/sync.R               keeps the store in step with Google Calendar
R/wall.R               week view: days, labels, colors
R/server.R             web server for the wall page and its API
www/                   the wall page (plain ES5 + flexbox for old tablets)
scripts/setup_mac.R    one-time setup on a Mac
scripts/smoke_test.R   checks sign-in, calendar read/write, inbox read
scripts/sync_once.R    one sync pass, then prints the next 7 days
scripts/sync_loop.R    syncs every minute until stopped (no web server)
scripts/server.R       sync loop plus the wall page, in one process
tests/run_tests.R      offline tests with a fake Google
tests/demo_server.R    wall page with made-up events, no Google needed
config.example.json    the fields the private config needs
```

## Private files

This repo is public. Nothing private goes in it. These live in
`~/.config/moonrise/` on each machine:

| File                 | What it is                                   |
|----------------------|----------------------------------------------|
| `config.json`        | account, calendar IDs, allowed senders       |
| `client_secret.json` | Google OAuth Desktop client                  |
| `tokens/`            | saved Google sign-in                         |

`.gitignore` blocks these names too, in case a copy lands in the repo.

## Setup on a Mac

1. Install R from https://cloud.r-project.org/bin/macosx/
2. Put `moonrise_config.json` and the Google `client_secret_….json` in
   `~/Downloads`.
3. In R, from this folder:

   ```r
   source("scripts/setup_mac.R")
   source("scripts/smoke_test.R")
   ```

4. A browser opens. Sign in as the import account, click
   **Advanced > Go to Moonrise Calendar (unsafe)**, and allow both
   permissions.

## Sync

```r
source("scripts/sync_once.R")   # one pass, prints the next 7 days
```

```sh
Rscript scripts/sync_loop.R     # runs until Ctrl-C
```

Each minute the loop asks Google, using a sync token, whether anything
changed. Usually nothing has, and that costs one small request per
calendar. When something has changed, and once an hour regardless, it
fetches the window (31 days back to 400 days ahead) with repeating events
expanded and replaces the local copy in one transaction. The copy lives in
`~/.local/share/moonrise/moonrise.sqlite`.

Optional settings in `config.json`, shown with their defaults:

```json
"data_dir": "~/.local/share/moonrise",
"sync": { "every_seconds": 60, "refresh_minutes": 60,
          "days_back": 31, "days_ahead": 400 }
```

Event titles may start with initials and a dash, for example
`V N - Swim Lessons`. Initials come from `family` in the config, plus `F`
for the whole family. A leading `?` marks an import awaiting review.

## Wall page

```sh
Rscript scripts/server.R
```

It prints the address to open, for example `http://192.168.1.20:8080/`,
from any device on the home Wi-Fi. The page shows a rolling week starting
today, checks for changes every 15 seconds, and reloads itself at 3:30 AM
so it picks up new code. On a phone it stacks the days.

Colors follow these rules, using `adults` and `colors` from the config
(unlisted people get Okabe-Ito colors in order):

- one child, alone or with an adult: that child's color
- two or more children: the "children" color
- one adult alone: that adult's color
- `F`, or all the adults: the "family" color
- no initials: gray

To try layout changes without Google: `Rscript tests/demo_server.R`.

Fonts are Atkinson Hyperlegible and DM Serif Display (SIL Open Font
License), served from `www/fonts` so the tablet needs no internet.

## Tests

```sh
Rscript tests/run_tests.R
```

## Setup on Linux Mint (the server)

```sh
sudo apt install r-cran-gargle r-cran-httr r-cran-httpuv r-cran-jsonlite \
  r-cran-dbi r-cran-rsqlite r-cran-later r-cran-rlang r-cran-plumber
```

Then copy `~/.config/moonrise/` from the Mac, or put the two files in place
by hand and sign in again.

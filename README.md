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
R/events.R             forms to Google events; add, change, accept, delete
R/repeat.R             repeat rules: Google's RRULE text and the dates it gives
R/extract.R            email to text; prompt; checking the model's answer
R/ollama.R             calls the local Ollama model
R/import.R             email import loop
www/                   the wall page (plain ES5 + flexbox for old tablets)
scripts/setup_mac.R    one-time setup on a Mac
scripts/smoke_test.R   checks sign-in, calendar read/write, inbox read
scripts/sync_once.R    one sync pass, then prints the next 7 days
scripts/sync_loop.R    syncs every minute until stopped (no web server)
scripts/server.R       sync, email import and the wall page, in one process
tests/run_tests.R      offline tests with a fake Google
tests/fake_google.R    in-memory Google Calendar and Gmail for tests
tests/demo_server.R    wall page with a fake Google, editing and a sample import
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

Tap an event to change, accept or delete it (delete takes a second
tap). Tap **+** on a day to add an event, or the dinner row to set that
night's dinner. Changes go to Google first, then show on the wall.

A new event can repeat: every day, every week (on chosen weekdays),
every 2 weeks, monthly (on the same date, or the same weekday such as
"the second Tuesday"), or every year. It ends never, on a date, or
after a number of times. Save it as:

- **One series**: a single repeating event in Google. When you change
  or delete one, choose **This day** or **Whole series**. A whole-series
  change sets the name, people and time for every day; the days stay the
  same, and days already changed on their own keep their changes.
- **Separate events**: independent copies, one per date (up to 100),
  each changed on its own. These need an end.

To try the page without Google: `Rscript tests/demo_server.R`. Edits work
against a fake calendar, and a sample email is imported after a few
seconds.

## Email import

Forward an email to the import account from an address in
`allowed_senders`. Within a couple of minutes its events appear on the
wall tagged **Review**. Tap one to check it, then **Accept** (or edit,
or delete). The event's description in Google Calendar quotes the line
of the email it came from.

It needs [Ollama](https://ollama.com) running on the same computer, with
the model pulled:

```sh
ollama pull qwen3.5:4b
```

The default model, `qwen3.5:4b` (about 4 GB), reads images, so photos
of flyers go straight to it. Thinking is turned off (`"think": false`),
since it is slow and reading a date doesn't need it. For a model that
can't read images, set `"vision": false` and photos go through OCR
(tesseract) instead. PDF attachments are read with pdftools. Each email is read in a background R
process, so a slow model doesn't stall the wall page. If Ollama isn't
running, emails wait until it is.

Settings in `config.json`, shown with their defaults:

```json
"import": { "enabled": true, "every_seconds": 120, "lookback_days": 3,
            "model": "qwen3.5:4b", "think": false, "vision": true,
            "ollama_url": "http://localhost:11434",
            "keep_alive": "2m", "timeout_seconds": 600, "max_chars": 4000,
            "max_events": 15, "ocr": true, "calendar": "family" }
```

Two typefaces from one family: DM Serif Display for the date heading and
the edit sheet's title, DM Sans for everything else, form fields
included. Both are under the SIL Open Font License and served from
`www/fonts`, so the tablet needs no internet.

The icon (`www/icons/favicon.svg`, a crescent rising over an orange
horizon) has PNG copies for older browsers and phone home screens. To
redraw the PNGs after editing the SVG, render it at 32, 180, 192 and 512
pixels.

## Tests

```sh
Rscript tests/run_tests.R
```

## Setup on Linux Mint (the server)

```sh
sudo apt install r-cran-gargle r-cran-httr r-cran-httpuv r-cran-jsonlite \
  r-cran-dbi r-cran-rsqlite r-cran-later r-cran-rlang r-cran-plumber \
  r-cran-callr r-cran-xml2 r-cran-pdftools r-cran-tesseract
```

Then copy `~/.config/moonrise/` from the Mac, or put the two files in place
by hand and sign in again.

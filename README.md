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
scripts/setup_mint.sh  one-time setup of the server on Linux Mint
scripts/try_model.R    times one sample email through the import model
deploy/moonrise.service  systemd service (setup_mint.sh fills it in)
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
fetches the window (90 days back to 400 days ahead) with repeating events
expanded and replaces the local copy in one transaction. It also does a
full refresh when the server starts. The copy lives in
`~/.local/share/moonrise/moonrise.sqlite`.

Optional settings in `config.json`, shown with their defaults:

```json
"data_dir": "~/.local/share/moonrise",
"sync": { "every_seconds": 60, "refresh_minutes": 60,
          "days_back": 90, "days_ahead": 400 }
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

The arrows next to the date move a week back or ahead (so does a swipe on
a touch screen, or the arrow keys), and **Today** comes back. Left on
another week, the page returns to this week by itself after two minutes
untouched (not while the edit sheet is open). The wall can page as far
as the local copy goes: 90 days back and 400 ahead by default.

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
wall tagged **Review**, and a "1 to review" button at the top lists every
event awaiting review, whatever its date (the week only shows seven
days). Tap one to check it, then **Accept** (or edit, or delete). The
event's description in Google Calendar quotes the line of the email it
came from, and notes any date R corrected.

Small models are weak at counting days, so the prompt includes a
two-week calendar starting from the day the email was sent, and R itself
settles "today", "tonight", "tomorrow" and "this Saturday" (the first
Saturday on or after the day the email was sent). The server log names
the day and time of each event it adds.

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

The server is a 2008 MacBook Air running Linux Mint 21 or 22, on the home
Wi-Fi, lid closed. It runs one process under systemd: sync, email import
and the wall page.

### 1. Run the setup script

On the Air, in a terminal:

```sh
git clone https://github.com/bkerly/moonrise.git ~/moonrise
cd ~/moonrise
bash scripts/setup_mint.sh
```

It asks for your password for the sudo steps, and once for the Wi-Fi
password if the network was saved for your login only. It:

1. installs R and the packages from [r2u](https://github.com/eddelbuettel/r2u)
   (CRAN binaries for Ubuntu; Mint 21 is jammy, Mint 22 is noble)
2. turns on SSH, so the Pro can copy files over
3. makes `~/.config/moonrise` and `~/.local/share/moonrise`
4. ignores the lid and turns sleep off
   ([logind.conf](https://www.freedesktop.org/software/systemd/man/255/logind.conf.html))
5. turns off Wi-Fi power saving, and makes the Wi-Fi connect at boot
   without anyone logging in
6. opens the wall page port (and SSH) to the home network, if the
   firewall is on
7. installs Ollama and `qwen3.5:0.8b`, and tries it on a sample email
8. installs and enables the `moonrise` service

It is safe to run again. Reboot once afterwards.

In the router, reserve the Air's address (the script prints it) so the
wall page address never changes.

### 2. Move the server from the Pro

Only one server may run at a time: two would import the same emails
twice. On the Pro, stop the server (Ctrl-C), then copy the private files
and the local store:

```sh
scp -r ~/.config/moonrise/config.json ~/.config/moonrise/client_secret.json \
  ~/.config/moonrise/tokens  AIR_USER@AIR_ADDRESS:.config/moonrise/
scp ~/.local/share/moonrise/moonrise.sqlite  AIR_USER@AIR_ADDRESS:.local/share/moonrise/
```

The token works on the Air as is: same account, same client. The store
carries the list of emails already imported, so nothing is imported
twice. (Without it the Air rebuilds the calendar copy on its first sync,
but would read the last 3 days of email again.)

Then on the Air, set the import settings for the small model (next
section), and start the server:

```sh
sudo systemctl start moonrise
journalctl -u moonrise -f      # follow the log; Ctrl-C stops following
```

### 3. The model on the Air

Email import runs `qwen3.5:0.8b` (1.2 GB) in Ollama on the Air itself,
so it works with the Pro off. The setup script installs Ollama, limits
it to one model and one request at a time with a 4096-token context
(the least memory), pulls the model, and tries it on a sample email.
The Air is slow, so expect minutes per email, not seconds.

In the Air's `config.json`:

```json
"import": { "model": "qwen3.5:0.8b", "vision": false, "timeout_seconds": 1800 }
```

- `vision: false` sends photos through OCR (tesseract) instead of the
  model, since reading an image costs a small CPU far more than reading
  text.
- `timeout_seconds: 1800` gives each email up to 30 minutes.

To try the model again, or another one:

```sh
cd ~/moonrise && Rscript scripts/try_model.R qwen3.5:0.8b
```

It prints the time taken and the events found for the "hyrox sim this
saturday at 1230pm" email (right answer: Saturday Oct 31, 12:30, B).

The Air's Core 2 Duo has no AVX, and Ollama's docs list no CPU
requirements, so whether it runs at all is only known after trying.
If it doesn't, the fallback is Ollama on the Pro
(`"ollama_url": "http://PRO_ADDRESS:11434"`, and on the Pro
`launchctl setenv OLLAMA_HOST "0.0.0.0:11434"`, per the
[Ollama FAQ](https://docs.ollama.com/faq)); emails then wait while the
Pro is off.

Memory is tight with the desktop running. `bash scripts/setup_mint.sh
--no-desktop` makes the Air boot to a text console, leaving the
desktop's memory to the model; SSH from the Pro still works.

### 4. Day to day

```sh
sudo systemctl status moonrise     # running?
journalctl -u moonrise -f          # log
cd ~/moonrise && git pull && sudo systemctl restart moonrise   # update
```

A config change also needs `sudo systemctl restart moonrise`. The
service restarts itself 15 seconds after a crash, and starts at boot.

From the Pro, `ssh AIR_USER@AIR_ADDRESS` reaches the Air with the lid
closed.

## Wall tablet and phones

The wall page is `http://AIR_ADDRESS:8080/` from any device on the home
Wi-Fi. It needs no sign-in, so keep guests on the guest network.

**Fire tablet**, in Fully Kiosk Browser's settings
([feature list](https://www.fully-kiosk.com/docs/en/features/all)):

- Start URL: the wall page address
- Keep screen on
- Autostart on boot
- Web Auto Reload: reload when the network reconnects and on page load
  errors, so the page comes back after a Wi-Fi drop or a server restart

None of these need the paid PLUS license. Kiosk mode does, and isn't
needed.

**Phones**: open the address in Chrome, then menu > **Add to Home
screen**. Since the page is plain HTTP, the icon opens it in Chrome
rather than as a stand-alone app. The page stacks the days on a narrow
screen.

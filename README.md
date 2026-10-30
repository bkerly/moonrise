# Moonrise

A home-built family wall calendar: a small R server, an old Android tablet
on the wall, and a phone app. It reads and writes a shared Google Calendar
and adds events from forwarded emails.

The homepage and privacy policy (`index.html`, `privacy.html`) are served
by GitHub Pages for the Google sign-in screen.

## Layout

```
R/config.R             reads the private config
scripts/setup_mac.R    one-time setup on a Mac
scripts/smoke_test.R   checks sign-in, calendar read/write, inbox read
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

## Setup on Linux Mint (the server)

```sh
sudo apt install r-cran-gargle r-cran-httr r-cran-httpuv r-cran-jsonlite
```

Then copy `~/.config/moonrise/` from the Mac, or put the two files in place
by hand and sign in again.

# scripts/smoke_test.R
#
# Checks that the server can:
#   1. sign in as the import account
#   2. read both calendars
#   3. write to the family calendar (creates, then deletes, a test event)
#   4. read the import inbox
#
# Run from the repo folder.
#
# Install:
#   Mac (dev):          source("scripts/setup_mac.R")
#   Linux Mint (r2u):   sudo apt install r-cran-gargle r-cran-httr r-cran-httpuv r-cran-jsonlite
#
# httpuv is required. Without it gargle falls back to the out-of-band
# sign-in, which Google no longer allows for Desktop clients.
#
# First run: open R in a terminal and run
#   source("scripts/smoke_test.R")
# A browser opens for Google sign-in. Sign in as the import account,
# then click Advanced > Go to Moonrise Calendar (unsafe) and allow both
# permissions. Later runs reuse the saved token, so
# `Rscript scripts/smoke_test.R` works after that.

library(gargle)

`%||%` <- function(a, b) if (is.null(a)) b else a

# Private settings (account, calendar IDs, allowed senders) come from
# ~/.config/moonrise/config.json. See config.example.json.
source("R/config.R")
cfg <- moonrise_config()

scopes <- c(
  "https://www.googleapis.com/auth/calendar.events",
  "https://www.googleapis.com/auth/gmail.readonly"
)
write_test <- TRUE

# ---- Sign in ---------------------------------------------------------------

cache_dir <- cfg$token_cache
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
Sys.chmod(cache_dir, mode = "0700")

client <- gargle_oauth_client_from_json(cfg$client_json, name = "moonrise")

token <- gargle2.0_token(
  email  = cfg$account,
  client = client,
  scope  = scopes,
  cache  = cache_dir
)

# ---- Helpers ---------------------------------------------------------------

# body = NULL sends no body. An empty list() would go out as "[]", which
# Google rejects ("Root element must be a message").
google <- function(method, path, params = list(), body = NULL) {
  req  <- request_build(method = method, path = path, params = params,
                        body = body, token = token)
  resp <- request_make(req)
  if (method == "DELETE") {
    if (httr::status_code(resp) >= 300) response_process(resp)
    return(invisible(TRUE))
  }
  response_process(resp)
}

rfc3339 <- function(x) format(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

check <- function(label, expr, hint) {
  tryCatch({
    force(expr)
    cat(sprintf("PASS  %s\n", label))
    invisible(TRUE)
  }, error = function(e) {
    cat(sprintf("FAIL  %s\n      %s\n      Hint: %s\n",
                label, conditionMessage(e), hint))
    invisible(FALSE)
  })
}

list_events <- function(cal_id, from, to) {
  res <- google("GET", "calendar/v3/calendars/{calendarId}/events", params = list(
    calendarId   = cal_id,
    timeMin      = rfc3339(from),
    timeMax      = rfc3339(to),
    singleEvents = "true",
    orderBy      = "startTime",
    maxResults   = 250
  ))
  items <- res$items %||% list()
  data.frame(
    start = vapply(items, function(e) e$start$dateTime %||% e$start$date %||% "", ""),
    title = vapply(items, function(e) e$summary %||% "(no title)", ""),
    stringsAsFactors = FALSE
  )
}

header_value <- function(msg, name) {
  hits <- Filter(function(h) tolower(h$name) == tolower(name), msg$payload$headers)
  if (length(hits)) hits[[1]]$value else NA_character_
}

sender_address <- function(from) {
  addr <- regmatches(from, regexpr("[^<\\s]+@[^>\\s]+", from, perl = TRUE))
  if (length(addr)) tolower(addr) else NA_character_
}

# ---- 1. Read both calendars -----------------------------------------------

now  <- Sys.time()
week <- now + 7 * 24 * 3600
cat(sprintf("Now: %s\n\n", format(now, tz = cfg$tz, usetz = TRUE)))

for (nm in names(cfg$calendars)) {
  check(
    sprintf("read %s calendar", nm),
    {
      ev <- list_events(cfg$calendars[[nm]], now, week)
      cat(sprintf("      %d events in the next 7 days\n", nrow(ev)))
      if (nrow(ev)) print(head(ev, 10), row.names = FALSE)
    },
    "Check the calendar ID and that it is shared with the import account."
  )
}

# ---- 2. Write test on the family calendar ---------------------------------

test_title <- "? Moonrise test - delete me"
family_id  <- cfg$calendars[["family"]]

delete_event <- function(event_id) {
  google("DELETE", "calendar/v3/calendars/{calendarId}/events/{eventId}",
         params = list(calendarId = family_id, eventId = event_id))
}

if (write_test) {
  check(
    "write to family calendar",
    {
      # Remove test events left behind by an earlier run that failed midway.
      old <- google("GET", "calendar/v3/calendars/{calendarId}/events", params = list(
        calendarId   = family_id,
        q            = "Moonrise test",
        timeMin      = rfc3339(now - 7 * 24 * 3600),
        timeMax      = rfc3339(now + 7 * 24 * 3600),
        singleEvents = "true"
      ))$items %||% list()
      old <- Filter(function(e) identical(e$summary, test_title), old)
      for (e in old) delete_event(e$id)
      if (length(old)) {
        cat(sprintf("      removed %d leftover test event(s)\n", length(old)))
      }

      start <- now + 3600
      ev <- google("POST", "calendar/v3/calendars/{calendarId}/events",
        params = list(calendarId = family_id),
        body = list(
          summary = test_title,
          start   = list(dateTime = rfc3339(start)),
          end     = list(dateTime = rfc3339(start + 15 * 60))
        )
      )
      cat("      created test event\n")
      delete_event(ev$id)
      cat("      deleted test event\n")
    },
    "A 403 means the share needs 'Make changes to events'."
  )
}

# ---- 3. Read the import inbox ---------------------------------------------

check(
  "read import inbox",
  {
    res <- google("GET", "gmail/v1/users/me/messages",
                  params = list(q = "in:inbox", maxResults = 5))
    ids <- vapply(res$messages %||% list(), function(m) m$id, "")
    cat(sprintf("      %d recent messages\n", length(ids)))
    for (id in ids) {
      msg  <- google("GET", "gmail/v1/users/me/messages/{id}",
                     params = list(id = id, format = "metadata"))
      from <- header_value(msg, "From")
      ok   <- sender_address(from) %in% cfg$allowed_senders
      cat(sprintf("      [%s] %s | %s\n",
                  if (ok) "allowed" else "ignored",
                  from, header_value(msg, "Subject")))
    }
  },
  "Make sure the Gmail API is enabled in the Cloud project."
)

# R/extract.R
#
# Turning a Gmail message into text a small model can read, and checking
# what the model sends back. No network calls here, so it runs in the
# background job and in tests.

# ---- Gmail message parts ---------------------------------------------------

b64url_raw <- function(x) {
  if (is.null(x) || !nzchar(x)) return(raw())
  x <- chartr("-_", "+/", x)
  pad <- (4 - nchar(x) %% 4) %% 4
  jsonlite::base64_dec(paste0(x, strrep("=", pad)))
}

part_header <- function(part, name) {
  for (h in part$headers %||% list()) {
    if (tolower(h$name) == tolower(name)) return(h$value)
  }
  ""
}

# Text from raw bytes in the part's character set, as UTF-8.
raw_text <- function(bytes, charset = "") {
  if (!length(bytes)) return("")
  bytes <- bytes[bytes != as.raw(0)]
  txt <- rawToChar(bytes)
  cs  <- toupper(charset)
  if (nzchar(cs) && !cs %in% c("UTF-8", "UTF8", "US-ASCII")) {
    conv <- iconv(txt, from = cs, to = "UTF-8", sub = " ")
    if (!is.na(conv)) txt <- conv
  }
  Encoding(txt) <- "UTF-8"
  if (!validUTF8(txt)) txt <- iconv(txt, "UTF-8", "UTF-8", sub = " ")
  txt
}

# Flattens a Gmail payload into a list of leaf parts.
gmail_parts <- function(payload) {
  out <- list()
  walk <- function(p) {
    if (length(p$parts)) {
      for (q in p$parts) walk(q)
      return(invisible())
    }
    ctype   <- part_header(p, "Content-Type")
    charset <- sub('.*charset="?([^";]+)"?.*', "\\1", ctype, ignore.case = TRUE)
    if (identical(charset, ctype)) charset <- ""
    out[[length(out) + 1]] <<- list(
      mime          = tolower(p$mimeType %||% ""),
      filename      = p$filename %||% "",
      data          = p$body$data %||% "",
      attachment_id = p$body$attachmentId %||% "",
      size          = p$body$size %||% 0,
      charset       = charset
    )
  }
  walk(payload)
  out
}

html_to_text <- function(html) {
  if (!nzchar(html)) return("")
  # Line breaks where blocks end, before the tags disappear.
  html <- gsub("(?i)(<br\\b[^>]*>|</(p|div|li|tr|h[1-6]|table|ul|ol)>)",
               "\\1\n", html, perl = TRUE)
  doc <- tryCatch(xml2::read_html(html), error = function(e) NULL)
  if (is.null(doc)) return(gsub("<[^>]+>", " ", html))
  xml2::xml_remove(xml2::xml_find_all(doc, "//script|//style|//head"))
  xml2::xml_text(doc)
}

normalize_text <- function(x) {
  x <- gsub("\r\n?", "\n", x)
  x <- gsub("[\u00a0\t\u200b\u200c\u200d\ufeff]", " ", x, perl = TRUE)
  x <- gsub(" {2,}", " ", x)
  x <- gsub(" *\n *", "\n", x)
  x <- gsub("\n{3,}", "\n\n", x)
  trimws(x)
}

# Plain text of the message body. Prefers text/plain; falls back to HTML.
message_text <- function(parts) {
  body  <- Filter(function(p) !nzchar(p$filename), parts)
  plain <- Filter(function(p) p$mime == "text/plain", body)
  html  <- Filter(function(p) p$mime == "text/html", body)
  txt <- if (length(plain)) {
    paste(vapply(plain, function(p) raw_text(b64url_raw(p$data), p$charset), ""),
          collapse = "\n\n")
  } else if (length(html)) {
    paste(vapply(html, function(p) html_to_text(raw_text(b64url_raw(p$data), p$charset)), ""),
          collapse = "\n\n")
  } else ""
  normalize_text(txt)
}

# Drops quoted reply lines and anything after a signature marker.
clean_text <- function(x) {
  lines <- strsplit(x, "\n", fixed = TRUE)[[1]]
  lines <- lines[!grepl("^\\s*>", lines)]
  sig   <- which(lines %in% c("--", "-- "))
  if (length(sig)) lines <- lines[seq_len(sig[1] - 1)]
  normalize_text(paste(lines, collapse = "\n"))
}

# ---- Dates in text ---------------------------------------------------------

month_names <- c("jan", "feb", "mar", "apr", "may", "jun",
                 "jul", "aug", "sep", "oct", "nov", "dec")
weekday_names <- c("sun", "mon", "tue", "wed", "thu", "fri", "sat")

# The date in a forwarded message's "Date:" line, e.g.
# "Date: Mon, Oct 26, 2026 at 3:04 PM". NA if there isn't one.
forwarded_date <- function(x) {
  block <- regmatches(x, regexpr("(?is)forwarded message.*", x, perl = TRUE))
  if (!length(block)) return(as.Date(NA))
  line <- regmatches(block, regexpr("(?im)^date:.*$", block, perl = TRUE))
  if (!length(line)) return(as.Date(NA))
  m <- regmatches(line, regexec(
    "(?i)\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?\\s+(\\d{1,2}),?\\s+(\\d{4})",
    line, perl = TRUE))[[1]]
  if (length(m) != 4) return(as.Date(NA))
  as.Date(sprintf("%s-%02d-%02d", m[4], match(tolower(m[2]), month_names),
                  as.integer(m[3])))
}

date_words <- paste0(
  "(?i)\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?\\s+\\d{1,2}",
  "|\\b\\d{1,2}/\\d{1,2}\\b",
  "|\\b(mon|tues?|wed|thu|thurs|fri|sat|sun)[a-z]*\\b",
  "|\\b\\d{1,2}(:\\d{2})?\\s*(am|pm|a\\.m\\.|p\\.m\\.)",
  "|\\b(today|tomorrow|tonight|noon)\\b"
)

# Long emails: keep the first paragraph and the ones that mention dates
# or times, up to max_chars. Small models do better with less to read.
focus_text <- function(x, max_chars = 4000) {
  if (nchar(x) <= max_chars) return(x)
  paras <- strsplit(x, "\n\n", fixed = TRUE)[[1]]
  keep  <- grepl(date_words, paras, perl = TRUE)
  keep[1] <- TRUE
  out <- paste(paras[keep], collapse = "\n\n")
  if (nchar(out) > max_chars) out <- substr(out, 1, max_chars)
  out
}

# ---- Prompt ----------------------------------------------------------------

import_schema <- function() {
  list(
    type = "object",
    properties = list(events = list(
      type = "array",
      items = list(
        type = "object",
        properties = list(
          title      = list(type = "string"),
          date       = list(type = "string"),
          end_date   = list(type = "string"),
          start_time = list(type = "string"),
          end_time   = list(type = "string"),
          who        = list(type = "array", items = list(type = "string")),
          weekday    = list(type = "string"),
          quote      = list(type = "string")
        ),
        required = list("title", "date", "start_time", "end_time", "who",
                        "weekday", "quote")
      )
    )),
    required = list("events")
  )
}

long_date <- function(d) sub(" 0", " ", format(d, "%A, %B %d, %Y"))

# Two weeks of dates from the day the email was sent. Small models look
# dates up far more reliably than they count days.
day_table <- function(sent, days = 14) {
  d <- sent + 0:(days - 1)
  lines <- sprintf("%s %s", format(d, "%A"), format(d))
  lines[1] <- paste(lines[1], "(the day the email was sent)")
  paste(lines, collapse = "\n")
}

# The date that "today", "tonight", "tomorrow" or "this Saturday" points
# to, counted from the day the email was sent. NA if the text has none of
# these, or several that disagree.
relative_date <- function(text, sent) {
  t <- tolower(text %||% "")
  hits <- as.Date(character())
  if (grepl("\\b(today|tonight|this (morning|afternoon|evening))\\b", t, perl = TRUE)) {
    hits <- c(hits, sent)
  }
  if (grepl("\\btomorrow\\b", t, perl = TRUE)) hits <- c(hits, sent + 1)
  m <- regmatches(t, gregexpr("\\bthis (sun|mon|tue|wed|thu|fri|sat)[a-z]*\\b", t, perl = TRUE))[[1]]
  for (w in m) {
    wd   <- weekday_number(sub("^this ", "", w))
    next7 <- sent + 0:6
    hits <- c(hits, next7[as.POSIXlt(next7)$wday == wd])
  }
  hits <- unique(hits)
  if (length(hits) == 1) hits else as.Date(NA)
}

# Returns list(system = ..., user = ...).
build_prompt <- function(text, subject, sent, today, family) {
  people <- paste(sprintf("%s = %s", names(family), unlist(family)),
                  collapse = ", ")
  system <- paste0(
    "You find calendar events in emails for a family calendar.\n",
    "Today is ", long_date(today), ". ",
    "The email was sent on ", long_date(sent), ".\n",
    "Family members (initial = name): ", people, ".\n\n",
    "Rules:\n",
    "- Only include events with a specific day. Skip deadlines with no event, ",
    "ads, and anything already over.\n",
    "- Work out words like \"this Saturday\" or \"tomorrow\" from the day the ",
    "email was sent, using the calendar below. \"This Saturday\" is the first ",
    "Saturday on or after that day.\n",
    "- date and end_date are YYYY-MM-DD. end_date is the last day of a ",
    "multi-day event, otherwise \"\".\n",
    "- start_time and end_time are 24-hour HH:MM. Use \"\" for all-day events ",
    "or when no time is given.\n",
    "- who lists the initials of family members the event is for. Use [] if ",
    "the email doesn't say.\n",
    "- title is short (under 40 characters), with no date or time in it.\n",
    "- weekday is the day name the email gives for this date, like ",
    "\"Saturday\", or \"\" if it gives none.\n",
    "- quote copies the exact words from the email that give the date.\n",
    "- If there are no events, return {\"events\": []}.\n\n",
    "Calendar:\n", day_table(sent), "\n\n",
    "Answer with JSON matching this schema:\n",
    jsonlite::toJSON(import_schema(), auto_unbox = TRUE)
  )
  user <- paste0("Subject: ", subject, "\n\n", text)
  list(system = system, user = user)
}

# ---- Checking the model's answer ------------------------------------------

weekday_number <- function(x) {
  match(substr(tolower(trimws(x)), 1, 3), weekday_names) - 1
}

# Turns the model's events into forms for clean_form(), with notes for
# anything dropped or adjusted. Returns list(forms, notes).
validate_events <- function(events, cfg, today, sent, max_events = 15) {
  forms <- list()
  notes <- character()
  seen  <- character()
  known <- c(names(cfg$family), "F")
  str   <- function(x) if (is.null(x) || !length(x)) "" else trimws(as.character(x[[1]]))

  for (e in events) {
    title <- str(e$title)
    date  <- str(e$date)
    if (!nzchar(title)) { notes <- c(notes, "Skipped an event with no title."); next }
    if (!valid_date(date)) {
      notes <- c(notes, sprintf("Skipped \"%s\": no usable date.", title)); next
    }
    d <- as.Date(date)
    adjust <- ""

    # "Today", "tomorrow" and "this Saturday" have one right answer, so R
    # settles them instead of trusting the model's arithmetic.
    rel <- relative_date(str(e$quote), sent)
    if (!is.na(rel) && rel != d) {
      adjust <- sprintf("Date set to %s from \"%s\" in the email (the model said %s).",
                        format(rel), str(e$quote), format(d))
      d <- rel
    }

    # Small models slip on date arithmetic more than on copying a day
    # name, so a stated weekday wins when it is close.
    wd <- weekday_number(str(e$weekday))
    if (is.na(rel) && !is.na(wd) && as.POSIXlt(d)$wday != wd) {
      near <- d + c(-1, 1, -2, 2, -3, 3)
      hit  <- near[as.POSIXlt(near)$wday == wd]
      if (length(hit)) {
        adjust <- sprintf("Date moved from %s to %s to match \"%s\".",
                          format(d), format(hit[1]), str(e$weekday))
        d <- hit[1]
      }
    }

    if (d < today) {
      notes <- c(notes, sprintf("Skipped \"%s\": %s is in the past.", title, format(d)))
      next
    }
    if (d > today + 365) {
      notes <- c(notes, sprintf("Skipped \"%s\": %s is over a year away.", title, format(d)))
      next
    }

    start <- str(e$start_time)
    timed <- valid_time(start)
    end_date <- str(e$end_date)
    if (!valid_date(end_date) || as.Date(end_date) < d) end_date <- ""

    who <- toupper(unlist(e$who %||% list()))
    who <- unique(who[who %in% known])

    key <- paste(tolower(title), format(d), start)
    if (key %in% seen) next
    seen <- c(seen, key)

    forms[[length(forms) + 1]] <- list(
      title      = substr(title, 1, 120),
      who        = who,
      date       = format(d),
      all_day    = !timed,
      start_time = if (timed) start else "",
      end_time   = if (timed && valid_time(str(e$end_time))) str(e$end_time) else "",
      end_date   = if (timed) "" else end_date,
      pending    = TRUE,
      quote      = substr(str(e$quote), 1, 300),
      adjust     = adjust
    )
  }

  if (length(forms) > max_events) {
    notes <- c(notes, sprintf("Kept the first %d of %d events.", max_events, length(forms)))
    forms <- forms[seq_len(max_events)]
  }
  list(forms = forms, notes = notes)
}

# Event description shown in Google Calendar, so a reviewer can check it.
import_description <- function(form, subject, sender) {
  lines <- c(
    sprintf("Added by Moonrise from the email \"%s\" (%s).", subject, sender),
    if (nzchar(form$quote %||% "")) sprintf("The email says: \"%s\"", form$quote),
    if (nzchar(form$adjust %||% "")) form$adjust
  )
  paste(lines, collapse = "\n")
}

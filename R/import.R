# R/import.R
#
# Adds events from emails forwarded to the import account.
#
# Every couple of minutes:
# 1. List recent inbox messages the importer hasn't seen.
# 2. Skip senders not in allowed_senders (recorded as "ignored").
# 3. Fetch the text, plus PDF and photo attachments.
# 4. In a background R process, read attachments (PDF text, photo OCR),
#    trim the text, and ask the local Ollama model for events. The model
#    can take a minute on an old laptop; the wall page keeps working.
# 5. Back here: check the answer (dates, weekday, range), add each event
#    to the family calendar with a "?" so it shows as "Review" on the
#    wall, and record the result.
#
# If Ollama isn't running, nothing is recorded and the email is tried
# again next pass. Other failures are retried up to three times.

gmail_messages_path <- "gmail/v1/users/me/messages"

gmail_header <- function(msg, name) {
  for (h in msg$payload$headers %||% list()) {
    if (tolower(h$name) == tolower(name)) return(h$value)
  }
  ""
}

sender_address <- function(from) {
  addr <- regmatches(from, regexpr("[^<\\s]+@[^>\\s]+", from, perl = TRUE))
  if (length(addr)) tolower(addr) else ""
}

record_import <- function(con, id, ...) {
  v <- list(...)
  v$processed <- as.numeric(Sys.time())
  have <- nrow(DBI::dbGetQuery(con, "SELECT 1 FROM imports WHERE message_id = ?",
                               params = list(id)))
  if (!have) {
    DBI::dbExecute(con, "INSERT INTO imports (message_id) VALUES (?)",
                   params = list(id))
  }
  sets <- paste(sprintf("%s = ?", names(v)), collapse = ", ")
  DBI::dbExecute(con, sprintf("UPDATE imports SET %s WHERE message_id = ?", sets),
                 params = unname(c(v, list(id))))
}

# Message ids in the inbox the importer still needs to look at.
gmail_new_ids <- function(google, con, cfg) {
  res <- google("GET", gmail_messages_path, params = list(
    q = sprintf("in:inbox newer_than:%dd", as.integer(cfg$import$lookback_days)),
    maxResults = 50
  ))
  ids  <- vapply(res$messages %||% list(), function(m) m$id, "")
  done <- DBI::dbGetQuery(con, "
    SELECT message_id FROM imports WHERE status != 'error' OR attempts >= 3")$message_id
  rev(setdiff(ids, done))   # oldest first
}

# Everything the background job needs, fetched with this process's token.
prepare_input <- function(google, msg, cfg) {
  parts <- gmail_parts(msg$payload)
  text  <- message_text(parts)
  sent  <- forwarded_date(text)
  if (is.na(sent)) {
    sent <- as.Date(as.POSIXct(as.numeric(msg$internalDate) / 1000,
                               origin = "1970-01-01", tz = cfg$tz), tz = cfg$tz)
  }

  wanted <- function(p) {
    nzchar(p$filename) && nzchar(p$attachment_id) && p$size <= 10e6 &&
      (p$mime == "application/pdf" ||
         (p$mime %in% c("image/jpeg", "image/png") && p$size >= 20e3))
  }
  attachments <- lapply(Filter(wanted, parts), function(p) {
    a <- google("GET", paste0(gmail_messages_path, "/{messageId}/attachments/{id}"),
                params = list(messageId = msg$id, id = p$attachment_id))
    list(filename = p$filename, mime = p$mime, data = b64url_raw(a$data))
  })

  list(
    id          = msg$id,
    subject     = gmail_header(msg, "Subject"),
    sender      = sender_address(gmail_header(msg, "From")),
    text        = text,
    sent        = format(sent),
    attachments = attachments
  )
}

# ---- Background job --------------------------------------------------------

# Text from an attachment, or "" if the needed package isn't installed.
attachment_text <- function(a, ocr = TRUE) {
  if (a$mime == "application/pdf") {
    if (!requireNamespace("pdftools", quietly = TRUE)) return("")
    return(paste(pdftools::pdf_text(a$data), collapse = "\n\n"))
  }
  if (ocr && requireNamespace("tesseract", quietly = TRUE)) {
    return(tesseract::ocr(a$data))
  }
  ""
}

# Runs in a separate R process. Returns list(content, chars, notes).
import_job <- function(input, opts, family, today, chat = ollama_chat) {
  notes  <- character()
  text   <- clean_text(input$text)
  images <- list()
  for (a in input$attachments) {
    # A model that reads images gets photos as they are; OCR is for
    # models that can't, and does poorly on decorated flyers.
    if (isTRUE(opts$vision) && startsWith(a$mime, "image/")) {
      images[[length(images) + 1]] <- jsonlite::base64_enc(a$data)
      text <- paste0(text, "\n\n(Attached photo: ", a$filename, ")")
      next
    }
    t <- tryCatch(attachment_text(a, isTRUE(opts$ocr)),
                  error = function(e) structure("", error = conditionMessage(e)))
    if (!is.null(attr(t, "error"))) {
      notes <- c(notes, sprintf("Couldn't read %s: %s", a$filename, attr(t, "error")))
      next
    }
    t <- normalize_text(paste(t, collapse = "\n"))
    if (nzchar(t)) {
      text <- paste0(text, "\n\nAttachment ", a$filename, ":\n", t)
    } else {
      notes <- c(notes, sprintf("No text found in %s.", a$filename))
    }
  }
  text   <- focus_text(text, opts$max_chars)
  prompt <- build_prompt(text, input$subject, as.Date(input$sent),
                         as.Date(today), family)
  prompt$images <- images
  list(content = chat(prompt, import_schema(), opts),
       chars = nchar(text), notes = notes)
}

# How the job runs. The default starts a background R process; tests pass
# a runner that calls import_job() directly.
background_runner <- function(root = getwd()) {
  function(input, opts, family, today) {
    p <- callr::r_bg(
      function(root, input, opts, family, today) {
        for (f in list.files(file.path(root, "R"), "\\.R$", full.names = TRUE)) {
          source(f)
        }
        import_job(input, opts, family, today)
      },
      args = list(root, input, opts, family, today),
      supervise = TRUE
    )
    list(done = function() !p$is_alive(), result = function() p$get_result())
  }
}

inline_runner <- function(chat = ollama_chat) {
  function(input, opts, family, today) {
    out <- tryCatch(list(value = import_job(input, opts, family, today, chat)),
                    error = function(e) list(error = conditionMessage(e)))
    list(done = function() TRUE,
         result = function() {
           if (!is.null(out$error)) stop(out$error, call. = FALSE)
           out$value
         })
  }
}

# ---- Main loop -------------------------------------------------------------

# Adds the events for one finished job. Returns the number added.
finish_import <- function(google, con, cfg, job, result) {
  input  <- job$input
  today  <- as.Date(job$today)
  parsed <- tryCatch(jsonlite::fromJSON(result$content, simplifyVector = FALSE),
                     error = function(e) NULL)
  if (is.null(parsed) || !is.list(parsed$events %||% NULL)) {
    stop("The model's answer wasn't the JSON asked for.", call. = FALSE)
  }

  v <- validate_events(parsed$events, cfg, today, as.Date(input$sent),
                       cfg$import$max_events)
  ids <- character()
  for (form in v$forms) {
    body <- event_body(clean_form(form, cfg), cfg)
    body$description <- import_description(form, input$subject, input$sender)
    body$extendedProperties <- list(private = list(moonrise_import = input$id))
    ev  <- event_insert(google, cfg, cfg$import$calendar, body)
    ids <- c(ids, ev$id)
  }
  if (length(ids)) sync_calendar(google, con, cfg, cfg$import$calendar)

  record_import(con, input$id,
    status    = if (length(ids)) "added" else "no events",
    events    = length(ids),
    event_ids = paste(ids, collapse = " "),
    note      = paste(c(result$notes, v$notes), collapse = " "))
  length(ids)
}

# One step of the importer. Returns TRUE if there may be more to do soon.
import_tick <- function(google, con, cfg, state, runner, now = Sys.time()) {
  opts   <- cfg$import
  family <- cfg$family

  # A job is running: wait for it, then add its events.
  if (!is.null(state$job)) {
    job <- state$job
    if (!job$handle$done()) return(FALSE)
    state$job <- NULL
    tryCatch({
      result <- job$handle$result()
      n <- finish_import(google, con, cfg, job, result)
      state$problem <- NULL
      moonrise_log("import: \"%s\" from %s: %s", job$input$subject,
                   job$input$sender,
                   if (n) sprintf("added %d event%s for review", n, if (n == 1) "" else "s")
                   else "no events found")
    }, error = function(e) {
      msg <- conditionMessage(e)
      if (grepl(ollama_unreachable, msg, fixed = TRUE)) {
        # Not the email's fault: leave it unrecorded and try again later.
        if (!identical(state$problem, msg)) moonrise_log("import: %s", msg)
        state$problem <- msg
        return()
      }
      tries <- DBI::dbGetQuery(con,
        "SELECT attempts FROM imports WHERE message_id = ?",
        params = list(job$input$id))$attempts
      tries <- if (length(tries)) tries + 1 else 1
      record_import(con, job$input$id, status = "error", attempts = tries,
                    sender = job$input$sender, subject = job$input$subject,
                    note = msg)
      moonrise_log("import: \"%s\": error (try %d of 3): %s",
                   job$input$subject, tries, msg)
    })
    # Busy again soon, unless Ollama is down: then wait the usual interval.
    return(is.null(state$problem))
  }

  ids <- gmail_new_ids(google, con, cfg)
  for (id in ids) {
    msg    <- google("GET", paste0(gmail_messages_path, "/{id}"),
                     params = list(id = id, format = "full"))
    sender <- sender_address(gmail_header(msg, "From"))
    subject <- gmail_header(msg, "Subject")
    received <- as.numeric(msg$internalDate) / 1000

    if (!sender %in% cfg$allowed_senders) {
      record_import(con, id, status = "ignored", sender = sender,
                    subject = subject, received = received, events = 0)
      next
    }

    record_import(con, id, sender = sender, subject = subject,
                  received = received)
    input <- prepare_input(google, msg, cfg)
    today <- format(as.Date(now, tz = cfg$tz))
    state$job <- list(input = input, today = today,
                      handle = runner(input, opts, family, today))
    return(TRUE)
  }
  FALSE
}

# Runs import_tick on a timer: quickly while there is work, every
# cfg$import$every_seconds otherwise. Errors are logged once and retried.
start_import_loop <- function(google, con, cfg, runner = background_runner()) {
  state <- new.env()
  state$job <- NULL
  state$problem <- NULL
  state$error <- NULL

  tick <- function() {
    busy <- tryCatch({
      out <- import_tick(google, con, cfg, state, runner)
      if (!is.null(state$error)) moonrise_log("import: working again")
      state$error <- NULL
      out
    }, error = function(e) {
      msg <- conditionMessage(e)
      if (!identical(state$error, msg)) moonrise_log("import: error: %s", msg)
      state$error <- msg
      FALSE
    })
    wait <- if (!is.null(state$job)) 2 else if (busy) 1 else cfg$import$every_seconds
    later::later(tick, wait)
  }
  tick()
  invisible(state)
}

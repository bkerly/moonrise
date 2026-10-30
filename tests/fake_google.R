# tests/fake_google.R
#
# An in-memory stand-in for Google Calendar and Gmail, enough for the
# sync loop, the edit endpoints and the importer. Used by run_tests.R and
# demo_server.R.
#
#   fg <- fake_google(calendars = c(family = "fam@group", dinner = "din@group"))
#   fg$add_event("family", list(summary = "V - Swim", start = ..., end = ...))
#   fg$add_email(list(...))
#   google <- fg$google      # same signature as moonrise_google()'s result

fake_google <- function(calendars) {
  env <- new.env()
  env$events  <- setNames(lapply(calendars, function(x) list()), names(calendars))
  env$changes <- setNames(as.list(rep(0, length(calendars))), names(calendars))
  env$tokens  <- setNames(as.list(rep(0, length(calendars))), names(calendars))
  env$emails  <- list()
  env$calls   <- list()
  env$next_id <- 0

  cal_name <- function(id) {
    k <- names(calendars)[calendars == id]
    if (!length(k)) stop("Client error: (404) Not Found\nNo calendar ", id)
    k
  }
  new_id <- function(prefix) {
    env$next_id <- env$next_id + 1
    paste0(prefix, env$next_id)
  }
  find <- function(k, id) {
    for (i in seq_along(env$events[[k]])) {
      if (identical(env$events[[k]][[i]]$id, id)) return(i)
    }
    stop("Client error: (404) Not Found\nNo event ", id)
  }
  # Google sends dateTime with an offset; the fake converts local times
  # sent with timeZone the same way.
  normalize_time <- function(x) {
    if (!is.null(x$dateTime) && !is.null(x$timeZone) &&
        !grepl("([+-]\\d{2}:?\\d{2}|Z)$", x$dateTime)) {
      t <- as.POSIXct(x$dateTime, format = "%Y-%m-%dT%H:%M:%S", tz = x$timeZone)
      x$dateTime <- sub("(\\d{2})(\\d{2})$", "\\1:\\2",
                        format(t, "%Y-%m-%dT%H:%M:%S%z", tz = x$timeZone))
    }
    x
  }

  # ---- Repeating events, expanded the way Google does: instance ids are
  # "<series id>_<yyyymmdd>", each with recurringEventId. Single-day
  # changes and cancellations are kept as exceptions.
  env$exceptions <- list()
  is_instance <- function(id) grepl("_\\d{8}$", id)

  expand_all <- function(events, horizon) {
    out <- list()
    for (ev in events) {
      if (is.null(ev$recurrence)) { out[[length(out) + 1]] <- ev; next }
      all_day <- !is.null(ev[["start"]][["date"]])   # [[ ]]: $date would match dateTime
      first   <- as.Date(if (all_day) ev[["start"]][["date"]] else substr(ev$start$dateTime, 1, 10))
      tz      <- ev$start$timeZone %||% "UTC"
      days    <- repeat_dates(parse_rrule(ev$recurrence[[1]], first, tz), horizon = horizon)
      span    <- as.Date(if (all_day) ev[["end"]][["date"]] else substr(ev$end$dateTime, 1, 10)) - first
      for (d in as.list(days)) {
        inst <- ev
        inst$recurrence <- NULL
        inst$id <- paste0(ev$id, "_", format(d, "%Y%m%d"))
        inst$recurringEventId <- ev$id
        if (all_day) {
          inst$start <- list(date = format(d))
          inst$end   <- list(date = format(d + span))
        } else {
          inst$start <- normalize_time(list(
            dateTime = paste0(format(d), substr(ev$start$dateTime, 11, 19)), timeZone = tz))
          inst$end <- normalize_time(list(
            dateTime = paste0(format(d + span), substr(ev$end$dateTime, 11, 19)), timeZone = tz))
        }
        ex <- env$exceptions[[inst$id]]
        if (!is.null(ex)) {
          if (identical(ex$status, "cancelled")) next
          inst <- utils::modifyList(inst, ex)
        }
        out[[length(out) + 1]] <- inst
      }
    }
    out
  }

  env$add_event <- function(k, ev) {
    ev$id     <- ev$id %||% new_id("ev")
    ev$status <- ev$status %||% "confirmed"
    env$events[[k]][[length(env$events[[k]]) + 1]] <- ev
    env$changes[[k]] <- env$changes[[k]] + 1
    invisible(ev$id)
  }

  env$add_email <- function(m) {
    m$id <- m$id %||% new_id("msg")
    env$emails[[length(env$emails) + 1]] <- m
    invisible(m$id)
  }

  env$google <- function(method, path, params = list(), body = NULL) {
    env$calls[[length(env$calls) + 1]] <- list(method = method, path = path,
                                               params = params, body = body)
    # ---- Gmail
    if (startsWith(path, "gmail/")) {
      if (grepl("/attachments/", path)) {
        for (m in env$emails) for (a in m$attachments_data %||% list()) {
          if (identical(a$id, params$id)) return(list(data = a$data))
        }
        stop("Client error: (404) Not Found\nNo attachment")
      }
      if (!is.null(params$id)) {
        for (m in env$emails) if (identical(m$id, params$id)) return(m)
        stop("Client error: (404) Not Found\nNo message")
      }
      return(list(messages = lapply(rev(env$emails), function(m) list(id = m$id))))
    }

    # ---- Calendar
    k <- cal_name(params$calendarId)
    if (method == "GET" && !is.null(params$eventId)) {
      return(env$events[[k]][[find(k, params$eventId)]])
    }
    if (method == "GET") {
      if (!is.null(params$timeMin)) {
        horizon <- as.Date(substr(params$timeMax, 1, 10)) + 1
        return(list(items = expand_all(env$events[[k]], horizon)))
      }
      n <- if (is.null(params$syncToken)) length(env$events[[k]]) else env$changes[[k]]
      env$changes[[k]] <- 0
      env$tokens[[k]]  <- env$tokens[[k]] + 1
      return(list(items = rep(list(list(id = "x")), n),
                  nextSyncToken = paste0(k, env$tokens[[k]])))
    }
    if (method == "POST") {
      body$start <- normalize_time(body$start)
      body$end   <- normalize_time(body$end)
      id <- env$add_event(k, body)
      return(env$events[[k]][[find(k, id)]])
    }
    if (method == "PATCH" && is_instance(params$eventId)) {
      ex <- env$exceptions[[params$eventId]] %||% list()
      for (f in names(body)) {
        ex[[f]] <- if (f %in% c("start", "end")) normalize_time(body[[f]]) else body[[f]]
      }
      env$exceptions[[params$eventId]] <- ex
      env$changes[[k]] <- env$changes[[k]] + 1
      return(ex)
    }
    if (method == "DELETE" && is_instance(params$eventId)) {
      env$exceptions[[params$eventId]] <- list(status = "cancelled")
      env$changes[[k]] <- env$changes[[k]] + 1
      return(invisible(TRUE))
    }
    if (method == "PATCH") {
      i  <- find(k, params$eventId)
      ev <- env$events[[k]][[i]]
      for (f in names(body)) {
        ev[[f]] <- if (f %in% c("start", "end")) normalize_time(body[[f]]) else body[[f]]
      }
      env$events[[k]][[i]] <- ev
      env$changes[[k]] <- env$changes[[k]] + 1
      return(ev)
    }
    if (method == "DELETE") {
      i <- find(k, params$eventId)
      env$events[[k]] <- env$events[[k]][-i]
      env$changes[[k]] <- env$changes[[k]] + 1
      return(invisible(TRUE))
    }
    stop("fake_google: unsupported ", method, " ", path)
  }
  env
}

# A Gmail message in the shape messages.get(format = "full") returns.
fake_email <- function(from, subject, text = NULL, html = NULL,
                       sent = Sys.time(), attachments = list()) {
  enc <- function(x) {
    b <- jsonlite::base64_enc(charToRaw(enc2utf8(x)))
    gsub("=+$", "", chartr("+/", "-_", gsub("\n", "", b)))
  }
  hdr <- function(n, v) list(name = n, value = v)
  part <- function(mime, x) {
    list(mimeType = mime,
         headers = list(hdr("Content-Type", paste0(mime, "; charset=\"UTF-8\""))),
         filename = "", body = list(size = nchar(x), data = enc(x)))
  }
  body_parts <- c(if (!is.null(text)) list(part("text/plain", text)),
                  if (!is.null(html)) list(part("text/html", html)))
  # Attachment ids must be unique across all fake emails.
  att_ids <- vapply(attachments, function(a) paste0("att_", rlang::hash(a$raw)), "")
  att_parts <- lapply(seq_along(attachments), function(i) {
    a <- attachments[[i]]
    list(mimeType = a$mime, filename = a$filename, headers = list(),
         body = list(size = a$size %||% length(a$raw),
                     attachmentId = att_ids[i]))
  })
  list(
    internalDate = format(round(as.numeric(sent) * 1000), scientific = FALSE),
    payload = list(
      mimeType = "multipart/mixed",
      headers = list(hdr("From", from), hdr("Subject", subject)),
      parts = c(list(list(mimeType = "multipart/alternative", parts = body_parts)),
                att_parts)
    ),
    attachments_data = lapply(seq_along(attachments), function(i) {
      b <- jsonlite::base64_enc(attachments[[i]]$raw)
      list(id = att_ids[i],
           data = gsub("=+$", "", chartr("+/", "-_", gsub("\n", "", b))))
    })
  )
}

# R/server.R
#
# The web server the wall tablet and phones talk to. It runs in the same
# R process as the sync loop: plumber drives the `later` event loop, so
# the sync timer keeps firing between requests.
#
#   GET /             redirects to /wall/
#   GET /wall/        the wall page (files in www/)
#   GET /api/version  small; the page polls it to know when to redraw
#   GET /api/week     the week view; ?start=YYYY-MM-DD (default today)

moonrise_router <- function(cfg, con, www = "www") {
  json <- plumber::serializer_unboxed_json(na = "null")

  pr <- plumber::pr()

  pr <- plumber::pr_get(pr, "/", function(res) {
    res$status <- 302
    res$setHeader("Location", "/wall/")
    ""
  }, serializer = plumber::serializer_text())

  pr <- plumber::pr_get(pr, "/api/version", function(res) {
    res$setHeader("Cache-Control", "no-store")
    v <- store_version(con)
    v$today <- format(as.Date(Sys.time(), tz = cfg$tz))
    v
  }, serializer = json)

  pr <- plumber::pr_get(pr, "/api/week", function(res, start = "") {
    res$setHeader("Cache-Control", "no-store")
    day <- if (nzchar(start)) {
      tryCatch(as.Date(start, format = "%Y-%m-%d"), error = function(e) NA)
    } else NULL
    if (!is.null(day) && is.na(day)) {
      res$status <- 400
      return(list(error = "start must look like 2026-11-02"))
    }
    week_payload(con, cfg, start = day)
  }, serializer = json)

  plumber::pr_static(pr, "/wall", www)
}

# Best guess at this machine's address on the home network, for the
# startup message. Returns NULL if it can't tell.
lan_address <- function() {
  try_cmd <- function(cmd, args) {
    out <- tryCatch(suppressWarnings(system2(cmd, args, stdout = TRUE,
                                             stderr = FALSE)),
                    error = function(e) character())
    out <- trimws(unlist(strsplit(out, "\\s+")))
    out[grepl("^\\d+\\.\\d+\\.\\d+\\.\\d+$", out)][1]
  }
  ip <- if (Sys.info()[["sysname"]] == "Darwin") {
    try_cmd("ipconfig", c("getifaddr", "en0"))
  } else {
    try_cmd("hostname", "-I")
  }
  if (length(ip) && !is.na(ip)) ip else NULL
}

# R/google.R
#
# Google sign-in and a small request helper, shared by every script.
#
#   google <- moonrise_google(cfg)
#   google("GET", "calendar/v3/calendars/{calendarId}/events",
#          params = list(calendarId = id))
#
# Path parts in {braces} are filled from `params`; other params become the
# query string. NULL params are dropped.

moonrise_scopes <- c(
  "https://www.googleapis.com/auth/calendar.events",
  "https://www.googleapis.com/auth/gmail.readonly"
)

# Signs in as cfg$account using the saved token. The first sign-in needs an
# interactive R session; after that the token is reused and refreshed as
# needed, so Rscript and long-running loops work.
moonrise_token <- function(cfg, scopes = moonrise_scopes) {
  dir.create(cfg$token_cache, recursive = TRUE, showWarnings = FALSE)
  Sys.chmod(cfg$token_cache, mode = "0700")
  client <- gargle::gargle_oauth_client_from_json(cfg$client_json,
                                                  name = "moonrise")
  gargle::gargle2.0_token(
    email  = cfg$account,
    client = client,
    scope  = scopes,
    cache  = cfg$token_cache
  )
}

# A 410 from Google means a sync token has expired. Callers catch this class
# and start over with a full sync.
moonrise_gone <- function() {
  structure(
    class = c("moonrise_gone", "error", "condition"),
    list(message = "Google says the sync token has expired (410).",
         call = NULL)
  )
}

# Returns a function google(method, path, params, body).
# body = NULL sends no body. An empty list() would go out as "[]", which
# Google rejects ("Root element must be a message").
moonrise_google <- function(cfg, scopes = moonrise_scopes,
                            token = moonrise_token(cfg, scopes)) {
  # httr's GET and POST turn a token into request settings themselves,
  # but its PATCH and PUT don't, and fail with "is.request(y) is not
  # TRUE". Converting once here works for every method.
  auth <- httr::config(token = token)
  function(method, path, params = list(), body = NULL) {
    req  <- gargle::request_build(method = method, path = path,
                                  params = params, body = body, token = auth)
    resp <- gargle::request_make(req)
    code <- httr::status_code(resp)
    if (code == 410) stop(moonrise_gone())
    if (method == "DELETE" && code < 300) return(invisible(TRUE))
    gargle::response_process(resp)
  }
}

# RFC 3339 time for Google's query parameters.
rfc3339 <- function(x) format(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

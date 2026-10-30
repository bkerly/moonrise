# R/config.R
#
# Reads the private settings file. The real file lives outside the repo at
# ~/.config/moonrise/config.json. Set MOONRISE_CONFIG to use another path.
# See config.example.json for the fields.

moonrise_config <- function(path = Sys.getenv("MOONRISE_CONFIG",
                                              "~/.config/moonrise/config.json")) {
  path <- path.expand(path)
  if (!file.exists(path)) {
    stop("No config file at ", path, ". Run scripts/setup_mac.R, or copy ",
         "config.example.json there and fill it in.", call. = FALSE)
  }

  cfg <- jsonlite::read_json(path, simplifyVector = TRUE)

  defaults <- list(
    client_json = "~/.config/moonrise/client_secret.json",
    token_cache = "~/.config/moonrise/tokens",
    data_dir    = "~/.local/share/moonrise",
    tz          = "America/Denver",
    family      = list(),
    adults      = character(),   # initials of the adults, e.g. ["B", "K"]
    colors      = list(),        # per initial; unlisted ones get Okabe-Ito
    group_colors = list(
      children = "#56B4E9",      # two or more children
      family   = "#000000",      # F, or all adults
      none     = "#8A8A8A"       # no initials
    ),
    server      = list(
      host = "0.0.0.0",          # listen on the home network
      port = 8080
    ),
    sync        = list(
      every_seconds   = 60,   # how often to check for changes
      refresh_minutes = 60,   # full window refresh even with no changes
      days_back       = 31,   # window kept on the wall
      days_ahead      = 400
    )
  )
  cfg <- utils::modifyList(defaults, cfg)

  need <- c("account", "calendars", "allowed_senders")
  gone <- setdiff(need, names(cfg))
  if (length(gone)) {
    stop("Config is missing: ", paste(gone, collapse = ", "), call. = FALSE)
  }

  cals <- setdiff(c("family", "dinner"), names(cfg$calendars))
  if (length(cals)) {
    stop("Config calendars is missing: ", paste(cals, collapse = ", "),
         call. = FALSE)
  }

  vals <- unlist(cfg, use.names = FALSE)
  if (any(grepl("REPLACE_ME|example\\.com|import-account@", vals))) {
    stop("Config at ", path, " still has placeholder values from ",
         "config.example.json.", call. = FALSE)
  }

  cfg$client_json     <- path.expand(cfg$client_json)
  cfg$token_cache     <- path.expand(cfg$token_cache)
  cfg$data_dir        <- path.expand(cfg$data_dir)
  cfg$allowed_senders <- tolower(cfg$allowed_senders)
  cfg
}

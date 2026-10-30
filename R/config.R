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
    tz          = "America/Denver"
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
  cfg$allowed_senders <- tolower(cfg$allowed_senders)
  cfg
}

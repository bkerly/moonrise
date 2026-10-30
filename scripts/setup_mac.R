# scripts/setup_mac.R
#
# One-time setup for developing Moonrise on a Mac (the MacBook Pro),
# before the Linux Mint server is ready.
#
# Needs R from CRAN: https://cloud.r-project.org/bin/macosx/
# (pick the Apple silicon or Intel build to match the Mac).
#
# Run from the repo folder:
#   source("scripts/setup_mac.R")
# It is safe to run more than once.

# ---- Packages --------------------------------------------------------------
# httpuv matters: without it gargle falls back to the out-of-band sign-in,
# which Google no longer allows for Desktop clients.

pkgs    <- c("gargle", "httr", "httpuv", "jsonlite")
missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing)) {
  install.packages(missing, repos = "https://cloud.r-project.org")
}
cat("Packages ready:", paste(pkgs, collapse = ", "), "\n")

# ---- Config folder ---------------------------------------------------------

cfg_dir   <- path.expand("~/.config/moonrise")
token_dir <- file.path(cfg_dir, "tokens")
for (d in c(cfg_dir, token_dir)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  Sys.chmod(d, mode = "0700")
}

# Copy a file from ~/Downloads into the config folder if it is not there yet.
# `pattern` is a regex for the downloaded name.
fetch_download <- function(pattern, target, what) {
  if (file.exists(target)) return(invisible(target))
  found <- list.files(path.expand("~/Downloads"), pattern = pattern,
                      full.names = TRUE)
  if (length(found) == 1) {
    file.copy(found, target)
    cat("Copied", basename(found), "to", target, "\n")
  } else if (length(found) > 1) {
    stop("Found several ", what, " files in ~/Downloads:\n  ",
         paste(basename(found), collapse = "\n  "),
         "\nCopy the right one to ", target, " and run this again.",
         call. = FALSE)
  } else {
    stop("No ", what, " found. Copy it to ", target,
         " and run this again.", call. = FALSE)
  }
  invisible(target)
}

# ---- Private config --------------------------------------------------------

config_path <- file.path(cfg_dir, "config.json")
fetch_download("^moonrise_config( \\(\\d+\\))?\\.json$", config_path,
               "moonrise_config.json")
Sys.chmod(config_path, mode = "0600")

source("R/config.R")
cfg <- moonrise_config(config_path)
cat("Config OK:", cfg$account, "\n")

# ---- OAuth client JSON -----------------------------------------------------

fetch_download("^client_secret_.*\\.json$", cfg$client_json,
               "client_secret JSON")
Sys.chmod(cfg$client_json, mode = "0600")

client <- jsonlite::read_json(cfg$client_json)
if (is.null(client$installed)) {
  stop("This JSON is not a Desktop app client (no 'installed' section). ",
       "Use the Desktop client from the moonrise Cloud project.", call. = FALSE)
}
if (is.null(client$installed$client_secret) ||
    !nzchar(client$installed$client_secret)) {
  stop("The JSON has no client secret. Add a new secret to the client in ",
       "Google Cloud and download the JSON again.", call. = FALSE)
}
cat("Client JSON OK:", client$installed$client_id, "\n\n")
cat("Next: source(\"scripts/smoke_test.R\")\n")

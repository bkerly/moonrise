# scripts/try_model.R
#
# Sends one sample email through the import's model step, without Google,
# and reports how long it took and which events came back. Use it to see
# whether a model runs on this computer, and how fast.
#
# From the repo folder:
#   Rscript scripts/try_model.R                  model from config.json
#   Rscript scripts/try_model.R qwen3.5:0.8b     another model
#
# Ollama must be running with the model pulled (ollama pull <model>).
# Works without config.json, using the import defaults.

for (f in list.files("R", "\\.R$", full.names = TRUE)) source(f)

cfg <- tryCatch(moonrise_config(), error = function(e) NULL)
opts <- if (is.null(cfg)) {
  # The defaults moonrise_config() would fill in, from a minimal config.
  tmp <- tempfile(fileext = ".json")
  writeLines('{"account": "x@gmail.com",
               "calendars": {"family": "f", "dinner": "d"},
               "allowed_senders": []}', tmp)
  moonrise_config(tmp)$import
} else {
  cfg$import
}
family <- if (is.null(cfg) || !length(cfg$family)) {
  list(B = "Brian", K = "Katharine")
} else {
  cfg$family
}

args <- commandArgs(trailingOnly = TRUE)
if (length(args)) opts$model <- args[[1]]
# A slow laptop may take many minutes on a first run, model load included.
opts$timeout_seconds <- max(opts$timeout_seconds, 1800)

# The first real import, sent Thursday Oct 29, 2026. The right answer is
# Saturday Oct 31 at 12:30 for B.
sent  <- as.Date("2026-10-29")
input <- list(
  subject     = "hyrox sim reminder",
  text        = "Brian - hyrox sim this saturday at 1230pm at the gym. Bring shoes.",
  sent        = format(sent),
  attachments = list()
)

cat(sprintf("Model %s at %s (think %s, timeout %d s)\n",
            opts$model, opts$ollama_url, format(opts$think),
            as.integer(opts$timeout_seconds)))
t0  <- Sys.time()
out <- tryCatch(import_job(input, opts, family, today = sent),
                error = function(e) { cat("FAILED:", conditionMessage(e), "\n"); NULL })
secs <- as.numeric(Sys.time() - t0, units = "secs")
if (is.null(out)) quit(status = 1)

cat(sprintf("Answer in %.0f s (includes loading the model if it wasn't loaded)\n", secs))
events <- tryCatch(jsonlite::fromJSON(out$content, simplifyVector = FALSE)$events,
                   error = function(e) NULL)
if (is.null(events)) {
  cat("The answer wasn't the JSON asked for:\n", out$content, "\n")
  quit(status = 1)
}
cfg_check <- list(family = family)
v <- validate_events(events, cfg_check, today = sent, sent = sent)
if (!length(v$forms)) cat("No events found.\n")
for (f in v$forms) {
  cat(sprintf("  %s | %s %s | who: %s\n", f$title, f$date,
              if (nzchar(f$start_time)) f$start_time else "(all day)",
              paste(f$who, collapse = " ")))
  if (nzchar(f$adjust)) cat("    R corrected the model:", f$adjust, "\n")
}
if (length(v$notes)) cat("Notes:", paste(v$notes, collapse = " "), "\n")
cat("Expected: Saturday 2026-10-31 at 12:30, who B\n")

# R/ollama.R
#
# Calls a local Ollama model with a JSON schema, so the reply is JSON in
# the shape we asked for.
# Docs: https://docs.ollama.com/api/chat
#       https://docs.ollama.com/capabilities/thinking
#       https://docs.ollama.com/capabilities/structured-outputs

ollama_unreachable <- "Ollama is not reachable"

# prompt: list(system, user, images). images are base64 strings, sent only
# when the model reads images (opts$vision).
# opts$think: FALSE turns off a thinking model's long reasoning, which is
# slow and not needed to read a date. NULL leaves the model's default.
ollama_chat <- function(prompt, schema, opts) {
  user <- list(role = "user", content = prompt$user)
  if (length(prompt$images)) user$images <- prompt$images
  body <- list(
    model      = opts$model,
    messages   = list(list(role = "system", content = prompt$system), user),
    format     = schema,
    stream     = FALSE,
    keep_alive = opts$keep_alive,
    options    = list(temperature = 0)
  )
  if (!is.null(opts$think)) body$think <- opts$think

  resp <- ollama_post(body, opts)
  # Some models refuse a think setting they don't support; ask again
  # without it rather than fail.
  if (httr::status_code(resp) == 400 && !is.null(body$think) &&
      grepl("think", httr::content(resp, as = "text", encoding = "UTF-8"))) {
    body$think <- NULL
    resp <- ollama_post(body, opts)
  }

  txt <- httr::content(resp, as = "text", encoding = "UTF-8")
  if (httr::status_code(resp) >= 300) {
    msg <- tryCatch(jsonlite::fromJSON(txt)$error, error = function(e) txt)
    stop(sprintf("Ollama error %d: %s", httr::status_code(resp), msg), call. = FALSE)
  }
  jsonlite::fromJSON(txt, simplifyVector = FALSE)$message$content
}

ollama_post <- function(body, opts) {
  tryCatch(
    httr::POST(
      paste0(sub("/+$", "", opts$ollama_url), "/api/chat"),
      body = jsonlite::toJSON(body, auto_unbox = TRUE),
      httr::content_type_json(),
      httr::timeout(opts$timeout_seconds)
    ),
    error = function(e) {
      if (grepl("(?i)connect|resolve|refused", conditionMessage(e), perl = TRUE)) {
        stop(sprintf("%s at %s.", ollama_unreachable, opts$ollama_url), call. = FALSE)
      }
      stop(conditionMessage(e), call. = FALSE)
    }
  )
}

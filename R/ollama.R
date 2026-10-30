# R/ollama.R
#
# Calls a local Ollama model with a JSON schema, so the reply is JSON in
# the shape we asked for.
# Docs: https://docs.ollama.com/api/chat
#       https://docs.ollama.com/capabilities/structured-outputs

ollama_unreachable <- "Ollama is not reachable"

ollama_chat <- function(prompt, schema, opts) {
  body <- list(
    model      = opts$model,
    messages   = list(
      list(role = "system", content = prompt$system),
      list(role = "user",   content = prompt$user)
    ),
    format     = schema,
    stream     = FALSE,
    keep_alive = opts$keep_alive,
    options    = list(temperature = 0)
  )
  resp <- tryCatch(
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
  txt <- httr::content(resp, as = "text", encoding = "UTF-8")
  if (httr::status_code(resp) >= 300) {
    msg <- tryCatch(jsonlite::fromJSON(txt)$error, error = function(e) txt)
    stop(sprintf("Ollama error %d: %s", httr::status_code(resp), msg), call. = FALSE)
  }
  jsonlite::fromJSON(txt, simplifyVector = FALSE)$message$content
}

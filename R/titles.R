# R/titles.R
#
# Event titles carry who is involved and whether an import still needs
# review:
#
#   "V N - Swim Lessons"      who = "V N",  title = "Swim Lessons"
#   "? K - Dentist"           pending, who = "K"
#   "F - Zoo day"             F = whole family
#   "Pick up dry cleaning"    no prefix: who = ""
#
# Initials must be capitals from the family list (plus F), separated by
# spaces, commas, "&", "+" or "/", and followed by "-", "–", "—" or ":".

parse_titles <- function(x, initials) {
  x       <- ifelse(is.na(x), "", x)
  chars   <- paste(unique(c(initials, "F")), collapse = "")
  one     <- sprintf("[%s]", chars)
  sep     <- "[\\s,&+/]*"
  pattern <- sprintf("^\\s*(\\?\\s*)?(%s(?:%s%s)*)\\s*[-\u2013\u2014:]\\s*(.*)$",
                     one, sep, one)

  pending <- grepl("^\\s*\\?", x, perl = TRUE)
  m       <- regmatches(x, regexec(pattern, x, perl = TRUE))

  who   <- character(length(x))
  title <- trimws(sub("^\\s*\\?\\s*", "", x, perl = TRUE))
  hit   <- lengths(m) == 4
  if (any(hit)) {
    raw        <- vapply(m[hit], `[`, "", 3)
    who[hit]   <- vapply(regmatches(raw, gregexpr(one, raw, perl = TRUE)),
                         function(v) paste(unique(v), collapse = " "), "")
    title[hit] <- trimws(vapply(m[hit], `[`, "", 4))
  }

  data.frame(pending = pending, who = who, title = title,
             stringsAsFactors = FALSE)
}

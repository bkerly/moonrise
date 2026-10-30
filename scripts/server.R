# scripts/server.R
#
# Runs the sync loop and the wall page server in one process.
#
# In a terminal, from the repo folder:
#   Rscript scripts/server.R
# Then open the address it prints, from any device on the home Wi-Fi.
# Stop with Ctrl-C.
#
# On a Mac, the first run may ask whether R may accept incoming network
# connections. Allow it, or other devices can't reach the page.

for (f in list.files("R", "\\.R$", full.names = TRUE)) source(f)

cfg    <- moonrise_config()
google <- moonrise_google(cfg)
con    <- store_open(cfg)

start_sync_loop(google, con, cfg)

port <- as.integer(cfg$server$port)
ip   <- lan_address()
moonrise_log("wall page on this computer: http://localhost:%d/", port)
if (!is.null(ip)) {
  moonrise_log("wall page on the home network: http://%s:%d/", ip, port)
}

plumber::pr_run(moonrise_router(cfg, con), host = cfg$server$host,
                port = port, docs = FALSE, quiet = TRUE)

#!/usr/bin/env bash
# scripts/setup_mint.sh
#
# One-time setup of the Moonrise server on Linux Mint (the MacBook Air).
# This one is shell, not R, because it installs R itself and sets up apt,
# systemd and the network.
#
# Run as your normal user (not root), from the repo folder:
#   bash scripts/setup_mint.sh
#   bash scripts/setup_mint.sh --no-desktop   also boot to a text console,
#                                             leaving more memory for the model
# It asks for your password for the steps that need sudo. Safe to run
# again; each step checks what is already done.
#
# What it does:
#   1. R and the packages Moonrise needs, as binaries from r2u
#   2. SSH, so the Pro can copy files over and you can manage the Air
#   3. folders for the private config, token and local store
#   4. keeps the laptop awake: lid close ignored, sleep turned off
#   5. Wi-Fi: power saving off, and connects at boot without a login
#   6. opens the wall page port to the home network if the firewall is on
#   7. Ollama and the email import model (qwen3.5:0.8b), tried once
#   8. the moonrise systemd service, started at boot
#
# Sources:
#   r2u:     https://github.com/eddelbuettel/r2u
#   logind:  https://www.freedesktop.org/software/systemd/man/255/logind.conf.html
#   Ollama:  https://docs.ollama.com/linux.md, https://docs.ollama.com/faq

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
user="$(id -un)"
home="$HOME"
model="${MOONRISE_MODEL:-qwen3.5:0.8b}"

no_desktop=false
for a in "$@"; do
  case "$a" in
    --no-desktop) no_desktop=true ;;
    *) echo "Unknown option: $a"; exit 1 ;;
  esac
done

step() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not with sudo. It calls sudo itself."
  exit 1
fi

# ---- Which Ubuntu release Mint is built on ---------------------------------
# lsb_release on Mint gives Mint's own name (e.g. "wilma"); r2u wants the
# Ubuntu one, which Mint records as UBUNTU_CODENAME.

# shellcheck source=/dev/null
. /etc/os-release
codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
case "$codename" in
  jammy|noble) ;;
  *) echo "r2u has packages for Ubuntu jammy and noble (Mint 21 and 22)."
     echo "This system is based on '${codename:-unknown}'."
     exit 1 ;;
esac
arch="$(dpkg --print-architecture)"
if [ "$arch" != "amd64" ]; then
  echo "r2u needs 64-bit Intel (amd64). This system is $arch."
  exit 1
fi

# ---- 1. R and packages ------------------------------------------------------

step "1. R and packages from r2u (Ubuntu $codename)"

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  wget ca-certificates gnupg git curl

keyring=/usr/share/keyrings/r2u.gpg
if [ ! -s "$keyring" ]; then
  gnupg_home="$(mktemp -d)"
  sudo gpg --homedir "$gnupg_home" --no-default-keyring --keyring "$keyring" \
    --keyserver keyserver.ubuntu.com \
    --recv-keys A1489FE2AB99A21A 67C2D66C4B1D4339 51716619E084DAB9
  sudo rm -rf "$gnupg_home"
fi
# apt reads keyrings as an unprivileged user.
sudo chmod 644 "$keyring"

sudo tee /etc/apt/sources.list.d/r2u.sources >/dev/null <<EOF
Types: deb
URIs: https://r2u.stat.illinois.edu/ubuntu
Suites: $codename
Components: main
Architectures: amd64
Signed-By: $keyring
EOF

# Current R from CRAN, which the r2u packages are built against.
sudo tee /etc/apt/sources.list.d/cran.sources >/dev/null <<EOF
Types: deb
URIs: https://cloud.r-project.org/bin/linux/ubuntu
Suites: $codename-cran40/
Signed-By: $keyring
EOF

# Prefer r2u over Ubuntu's older builds of the same packages.
sudo tee /etc/apt/preferences.d/99cranapt >/dev/null <<EOF
Package: *
Pin: release o=CRAN-Apt Project
Pin: release l=CRAN-Apt Packages
Pin-Priority: 700
EOF

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  r-base-core \
  r-cran-gargle r-cran-httr r-cran-httpuv r-cran-jsonlite \
  r-cran-dbi r-cran-rsqlite r-cran-later r-cran-rlang r-cran-plumber \
  r-cran-callr r-cran-xml2 r-cran-pdftools r-cran-tesseract \
  tesseract-ocr-eng
note "$(Rscript --version 2>&1)"

# ---- 2. SSH -----------------------------------------------------------------

step "2. SSH server"
sudo apt-get install -y --no-install-recommends openssh-server
sudo systemctl enable --now ssh
note "From the Pro: ssh $user@<this laptop's address>"

# ---- 3. Folders -------------------------------------------------------------

step "3. Folders"
install -d -m 700 "$home/.config/moonrise" "$home/.config/moonrise/tokens"
install -d -m 755 "$home/.local/share/moonrise"
note "config and token: $home/.config/moonrise"
note "local store:      $home/.local/share/moonrise"

# ---- 4. Stay awake ----------------------------------------------------------

step "4. Lid close ignored, sleep off"
sudo install -d /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/10-moonrise.conf >/dev/null <<EOF
# Moonrise: the laptop is a server; closing the lid does nothing.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
# Masking the sleep targets stops the desktop's power settings from
# suspending the laptop too.
sudo systemctl mask sleep.target suspend.target hibernate.target \
  hybrid-sleep.target >/dev/null
note "Takes full effect after a reboot."

# ---- 5. Wi-Fi ---------------------------------------------------------------

step "5. Wi-Fi"
sudo install -d /etc/NetworkManager/conf.d
sudo tee /etc/NetworkManager/conf.d/99-moonrise-wifi-powersave.conf >/dev/null <<EOF
# Moonrise: Wi-Fi power saving off (2 = disable), so the wall page and
# imports don't stall.
[connection]
wifi.powersave = 2
EOF

# A Wi-Fi network saved from the desktop may keep its password in your
# login keyring and belong to you alone. Then it only connects after you
# log in, and the server has no network after a power cut. Make it
# connect at boot for everyone instead.
wifi="$(nmcli -t -f NAME,TYPE connection show --active \
        | awk -F: '$2 == "802-11-wireless" { print $1; exit }')"
if [ -z "$wifi" ]; then
  note "No active Wi-Fi connection found. Connect to the home Wi-Fi and run this again."
else
  note "Wi-Fi: $wifi"
  perms="$(nmcli -g connection.permissions connection show "$wifi" || true)"
  if [ -n "$perms" ]; then
    sudo nmcli connection modify "$wifi" connection.permissions ""
    note "now available to all users"
  fi
  flags="$(nmcli -g 802-11-wireless-security.psk-flags connection show "$wifi" 2>/dev/null || true)"
  if [ -n "$flags" ] && [ "${flags%% *}" != "0" ]; then
    read -r -s -p "   Wi-Fi password for \"$wifi\" (stored for all users): " pw
    echo
    sudo nmcli connection modify "$wifi" \
      802-11-wireless-security.psk "$pw" 802-11-wireless-security.psk-flags 0
    unset pw
    note "password stored for all users"
  fi
  sudo nmcli connection modify "$wifi" connection.autoconnect yes
fi

# ---- 6. Firewall ------------------------------------------------------------

# shellcheck disable=SC2016  # R code, not shell
port="$(cd "$repo" && Rscript -e 'source("R/config.R");
  cat(tryCatch(moonrise_config()$server$port, error = function(e) 8080))' 2>/dev/null || echo 8080)"

step "6. Firewall"
if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then
  subnet="$(ip -o -4 route show scope link | awk '{ print $1; exit }')"
  sudo ufw allow from "$subnet" to any port "$port" proto tcp >/dev/null
  sudo ufw allow from "$subnet" to any port 22 proto tcp >/dev/null
  note "opened ports $port (wall page) and 22 (SSH) to $subnet"
else
  note "firewall is off; nothing to open"
fi

# ---- 7. Ollama ---------------------------------------------------------------

step "7. Ollama and $model"
if grep -qw avx /proc/cpuinfo; then
  note "CPU has AVX"
else
  note "CPU has no AVX. Ollama may be slow here or may not run; the test below shows which."
fi

if ! command -v ollama >/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi

# One model, one request at a time, a 4096-token context: the least
# memory Ollama will use. It still listens only to this laptop.
sudo install -d /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/10-moonrise.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_CONTEXT_LENGTH=4096"
EOF
sudo systemctl daemon-reload
sudo systemctl enable ollama >/dev/null
sudo systemctl restart ollama
for _ in $(seq 30); do ollama list >/dev/null 2>&1 && break; sleep 1; done

ollama pull "$model"
note "Trying $model on a sample email (slow on this laptop; up to 30 minutes)..."
if (cd "$repo" && timeout 1800 Rscript scripts/try_model.R "$model"); then
  note "The model runs. Put the import settings from the README in config.json."
else
  note "The model did not answer. See: journalctl -u ollama -e"
fi

if $no_desktop; then
  sudo systemctl set-default multi-user.target >/dev/null
  note "Boots to a text console from now on (undo: sudo systemctl set-default graphical.target)."
fi

# ---- 8. Service -------------------------------------------------------------

step "8. moonrise service"
rscript="$(command -v Rscript)"
sed -e "s|@USER@|$user|" -e "s|@HOME@|$home|" -e "s|@REPO@|$repo|" \
    -e "s|@RSCRIPT@|$rscript|" "$repo/deploy/moonrise.service" \
  | sudo tee /etc/systemd/system/moonrise.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable moonrise >/dev/null
note "enabled: starts at boot"

cfg="$home/.config/moonrise/config.json"
missing=()
[ -s "$cfg" ] || missing+=("config.json")
[ -s "$home/.config/moonrise/client_secret.json" ] || missing+=("client_secret.json")
[ -n "$(ls -A "$home/.config/moonrise/tokens" 2>/dev/null)" ] || missing+=("tokens/")

if [ ${#missing[@]} -eq 0 ]; then
  sudo systemctl restart moonrise
  note "started. Log: journalctl -u moonrise -f"
else
  note "not started yet. Missing from ~/.config/moonrise: ${missing[*]}"
  note "Copy them from the Pro (see README, \"Moving the server to the Air\"),"
  note "then: sudo systemctl start moonrise"
fi

ip="$(hostname -I | awk '{ print $1 }')"
step "Done"
note "Wall page: http://$ip:$port/"
note "Reserve $ip for this laptop in the router so the address never changes."
note "Reboot once so the lid and Wi-Fi settings take full effect."

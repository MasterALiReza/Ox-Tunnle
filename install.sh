#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  OX TUNNLE — Installer  v3.1.0
#  t.me/WexortYT
# ─────────────────────────────────────────────────────────────

REPO="https://raw.githubusercontent.com/MasterALiReza/Ox-Tunnle/main"
MANAGER_URL="$REPO/ox-tunnle.sh"
PY_URL="$REPO/ox-tunnle.py"

BIN="/usr/local/bin/ox-tunnle"
PY_DST="/opt/ox-tunnle/ox-tunnle.py"

# ── Colours (only if terminal) ────────────────────────────────
if [[ -t 1 ]]; then
  R="\033[0m" B="\033[1m" GRN="\033[32m" RED="\033[31m" CYN="\033[36m" YLW="\033[33m"
else
  R="" B="" GRN="" RED="" CYN="" YLW=""
fi

info() { echo -e "  ${CYN}[*]${R} $*"; }
ok()   { echo -e "  ${GRN}${B}[+]${R} $*"; }
err()  { echo -e "  ${RED}${B}[!]${R} $*" >&2; exit 1; }
warn() { echo -e "  ${YLW}[~]${R} $*"; }

echo ""
echo -e "  ${CYN}${B}╔══════════════════════════════════════╗${R}"
echo -e "  ${CYN}${B}║      🐂  OX TUNNLE  INSTALLER       ║${R}"
echo -e "  ${CYN}${B}╚══════════════════════════════════════╝${R}"
echo ""

# ── Root check ────────────────────────────────────────────────
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  err "Please run as root: sudo bash install.sh"
fi

# ── apt-get update (non-fatal) ────────────────────────────────
info "Updating package lists..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y > /dev/null 2>&1 || warn "apt-get update returned non-zero (continuing anyway)"

# ── Core deps ─────────────────────────────────────────────────
CORE_DEPS=(curl ca-certificates python3 screen iproute2)

info "Installing core dependencies..."
for dep in "${CORE_DEPS[@]}"; do
  if dpkg -s "$dep" > /dev/null 2>&1; then
    echo -e "    ${GRN}✔${R}  $dep (already installed)"
  else
    echo -e "    ${YLW}↓${R}  Installing $dep ..."
    apt-get install -y "$dep" > /dev/null 2>&1 \
      || warn "Could not install $dep — may still work"
  fi
done

# ── Download files ────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Downloading management script..."
if ! curl -fsSL --connect-timeout 10 --retry 3 "$MANAGER_URL" -o "$TMP/ox-tunnle"; then
  err "Failed to download manager from GitHub. Check your internet connection."
fi

info "Downloading tunnel core (Python)..."
if ! curl -fsSL --connect-timeout 10 --retry 3 "$PY_URL" -o "$TMP/ox-tunnle.py"; then
  err "Failed to download tunnel core from GitHub. Check your internet connection."
fi

# ── Sanity checks ─────────────────────────────────────────────
[[ -s "$TMP/ox-tunnle" ]]    || err "Downloaded manager is empty!"
[[ -s "$TMP/ox-tunnle.py" ]] || err "Downloaded tunnel core is empty!"

# Quick validation: first line must be a shebang
head -n1 "$TMP/ox-tunnle" | grep -q "^#!" \
  || err "Downloaded manager does not look like a script (bad download?)."

# ── Install files ─────────────────────────────────────────────
info "Installing files..."
install -m 0755 "$TMP/ox-tunnle"    "$BIN"
mkdir -p "$(dirname "$PY_DST")"
install -m 0755 "$TMP/ox-tunnle.py" "$PY_DST"

# ── Done ──────────────────────────────────────────────────────
echo ""
echo -e "  ${CYN}${B}═══════════════════════════════════════${R}"
ok  "Installation complete!"
echo -e "  ${CYN}${B}═══════════════════════════════════════${R}"
echo ""
echo -e "  ${B}Binary:${R}  $BIN"
echo -e "  ${B}Core:${R}    $PY_DST"
echo ""
echo -e "  ${GRN}${B}Run:${R}  sudo ox-tunnle"
echo ""

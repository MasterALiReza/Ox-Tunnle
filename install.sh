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

# ── Core deps check ───────────────────────────────────────────
CORE_DEPS=(curl ca-certificates python3 iproute2)
MISSING_DEPS=()
for dep in "${CORE_DEPS[@]}"; do
  case "$dep" in
    python3)
      command -v python3 >/dev/null 2>&1 || MISSING_DEPS+=("$dep")
      ;;
    curl)
      command -v curl >/dev/null 2>&1 || MISSING_DEPS+=("$dep")
      ;;
    iproute2)
      command -v ip >/dev/null 2>&1 || command -v ss >/dev/null 2>&1 || MISSING_DEPS+=("$dep")
      ;;
    *)
      if command -v dpkg >/dev/null 2>&1; then
        dpkg -s "$dep" >/dev/null 2>&1 || MISSING_DEPS+=("$dep")
      elif command -v rpm >/dev/null 2>&1; then
        rpm -q "$dep" >/dev/null 2>&1 || MISSING_DEPS+=("$dep")
      fi
      ;;
  esac
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
  info "Installing missing dependencies: ${MISSING_DEPS[*]} ..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    timeout 15 apt-get update -y > /dev/null 2>&1 || true
    timeout 30 apt-get install -y "${MISSING_DEPS[@]}" > /dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${MISSING_DEPS[@]}" > /dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${MISSING_DEPS[@]}" > /dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${MISSING_DEPS[@]}" > /dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "${MISSING_DEPS[@]}" > /dev/null 2>&1 || true
  fi
else
  ok "Core dependencies (curl, python3, iproute2) already installed."
fi

# ── Download files ────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

download_file() {
  local filename="$1" dst="$2"
  local urls=(
    "https://ghproxy.net/https://raw.githubusercontent.com/MasterALiReza/Ox-Tunnle/main/${filename}"
    "https://mirror.ghproxy.com/https://raw.githubusercontent.com/MasterALiReza/Ox-Tunnle/main/${filename}"
    "https://cdn.jsdelivr.net/gh/MasterALiReza/Ox-Tunnle@main/${filename}"
    "https://raw.githack.com/MasterALiReza/Ox-Tunnle/main/${filename}"
    "https://raw.githubusercontent.com/MasterALiReza/Ox-Tunnle/main/${filename}"
  )
  for url in "${urls[@]}"; do
    # Try normal curl, then insecure (-k) fallback if SSL cert is outdated on Iran VPS
    if curl -fsSL --connect-timeout 5 --retry 2 "$url" -o "$dst" 2>/dev/null \
       || curl -fsSLk --connect-timeout 5 --retry 2 "$url" -o "$dst" 2>/dev/null; then
      if [[ -s "$dst" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

info "Downloading management script..."
if ! download_file "ox-tunnle.sh" "$TMP/ox-tunnle"; then
  err "Failed to download manager from GitHub or CDN mirrors. Check your network."
fi

info "Downloading tunnel core (Python)..."
if ! download_file "ox-tunnle.py" "$TMP/ox-tunnle.py"; then
  err "Failed to download tunnel core from GitHub or CDN mirrors. Check your network."
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

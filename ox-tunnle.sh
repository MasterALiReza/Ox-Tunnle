#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
#  OX TUNNLE  — Management Script  v3.1.0
#  t.me/WexortYT
# ─────────────────────────────────────────────────────────────

APP_NAME="Ox Tunnle"
TG_CHANNEL="t.me/WexortYT"
VERSION="3.1.0"

GITHUB_REPO="github.com/MasterALiReza/Ox-Tunnle"
SCRIPT_FILENAME="ox-tunnle.sh"
SELF_URL="https://raw.githubusercontent.com/MasterALiReza/Ox-Tunnle/main/${SCRIPT_FILENAME}"

PY="/opt/ox-tunnle/ox-tunnle.py"
PY_URL="https://raw.githubusercontent.com/MasterALiReza/Ox-Tunnle/main/ox-tunnle.py"
INSTALL_PATH="/usr/local/bin/ox-tunnle"

BASE="/etc/ox_tunnle_manager"
CONF="$BASE/profiles"
LOG_DIR="/var/log/ox-tunnle"
MAX=10                          # slots per role

HC_SCRIPT="/usr/local/bin/ox-tunnle-health-check"
HC_CRON_TAG="# OxTunnleHealthCheck"

# ── Colors ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R="\033[0m"    DIM="\033[2m"   B="\033[1m"
  RED="\033[31m" GRN="\033[32m"  YLW="\033[33m"
  CYN="\033[36m" WHT="\033[97m"  MGN="\033[35m"
else
  R="" DIM="" B="" RED="" GRN="" YLW="" CYN="" WHT="" MGN=""
fi

# ── Basic helpers ─────────────────────────────────────────────
need_root() { [[ "$(id -u)" == "0" ]] || { echo "Run as root: sudo ox-tunnle"; exit 1; }; }
pause()     { echo ""; read -r -p "  Press Enter to continue..." _ < /dev/tty || true; }
have()      { command -v "$1" >/dev/null 2>&1; }

apt_try_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y "$@" >/dev/null 2>&1 || true
}

fetch_url_to() {
  local url="$1" out="$2"
  if have curl; then curl -fsSL "$url" -o "$out"
  else have wget || apt_try_install wget; wget -qO "$out" "$url"; fi
}

is_installed() { [[ -x "$INSTALL_PATH" ]]; }

ensure() {
  mkdir -p "$CONF" "$LOG_DIR" "$(dirname "$PY")"
  have screen  || apt_try_install screen
  have python3 || apt_try_install python3
  have curl    || apt_try_install curl
  have ss      || apt_try_install iproute2
  have crontab || apt_try_install cron
  if [[ ! -f "$PY" ]]; then
    _msg_info "Downloading Python core..."
    fetch_url_to "$PY_URL" "$PY" && chmod +x "$PY" || true
  fi
  [[ -f "$PY" ]] || { echo "ERROR: Missing $PY"; exit 1; }
}

# ── UI helpers ────────────────────────────────────────────────
_hr()   { echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 56))${R}"; }
_dhr()  { echo -e "  ${CYN}${DIM}$(printf '═%.0s' $(seq 1 56))${R}"; }
_msg_ok()   { echo -e "  ${GRN}${B}✔${R}  $*"; }
_msg_warn() { echo -e "  ${YLW}${B}!${R}  $*"; }
_msg_info() { echo -e "  ${CYN}${B}»${R}  $*"; }
_msg_err()  { echo -e "  ${RED}${B}✘${R}  $*"; }

_section() {
  local title="$1"
  local pad; pad=$(printf '─%.0s' $(seq 1 $((54 - ${#title} - 1))))
  echo -e "\n  ${CYN}${B}┤${R} ${B}${WHT}${title}${R} ${CYN}${DIM}${pad}${R}"
}

_menu_item() {
  printf "  ${CYN}${B}[%s]${R}  %b\n" "$1" "$2"
}

# ── Network info ──────────────────────────────────────────────
_get_public_ip() { curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || true; }
_get_ipinfo_field() {
  local field="$1" ip="$2"
  [[ -n "$ip" ]] || { echo ""; return; }
  local json; json="$(curl -fsSL --max-time 4 "https://ipinfo.io/${ip}/json" 2>/dev/null || true)"
  [[ -n "$json" ]] || { echo ""; return; }
  echo "$json" | tr -d '\n' | sed -n "s/.*\"${field}\":[ ]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}
_get_location() {
  local ip; ip="$(_get_public_ip)"
  local city country
  city="$(_get_ipinfo_field city "$ip")"
  country="$(_get_ipinfo_field country "$ip")"
  [[ -n "$city$country" ]] && echo "${city}${city:+, }${country}" || echo "Unknown"
}
_get_datacenter() {
  local ip; ip="$(_get_public_ip)"
  local org; org="$(_get_ipinfo_field org "$ip")"
  [[ -n "$org" ]] && echo "$org" || echo "Unknown"
}

# ── Input validation ──────────────────────────────────────────
_validate_ip() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  local o IFS='.'; read -r -a o <<< "$ip"
  for oct in "${o[@]}"; do [[ "$oct" -ge 0 && "$oct" -le 255 ]] || return 1; done
}
_validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}
_read_ip() {
  local prompt="$1" ip
  while true; do
    read -r -p "  ${prompt}: " ip < /dev/tty
    ip="${ip//[^0-9.]/}"
    if _validate_ip "$ip"; then echo "$ip"; return; fi
    _msg_warn "Invalid IP address. Try again."
  done
}
_read_port() {
  local prompt="$1" default="${2:-}" p
  while true; do
    read -r -p "  ${prompt}${default:+ [${default}]}: " p < /dev/tty
    p="${p:-$default}"; p="${p//[^0-9]/}"
    if _validate_port "$p"; then echo "$p"; return; fi
    _msg_warn "Invalid port (1–65535). Try again."
  done
}

# ── Session management ────────────────────────────────────────
_session_name() { echo "ox_tunnle_$1"; }

# FIX BUG-ISRUNNING: use grep -qF (fixed string) — avoids tab/space and regex mismatches
_is_running() {
  local s; s="$(_session_name "$1")"
  screen -ls 2>/dev/null | grep -qF "$s"
}

# FIX BUG-DELETE: stop_slot now waits up to 3s for clean exit, then force-kills
_stop_slot() {
  local prof="$1" s; s="$(_session_name "$prof")"
  _is_running "$prof" || { return 0; }                # already stopped
  screen -S "$s" -X quit >/dev/null 2>&1 || true
  local i=0
  while [[ $i -lt 6 ]] && _is_running "$prof"; do
    sleep 0.5; i=$((i + 1))
  done
  # Force-kill if still alive after 3s
  if _is_running "$prof"; then
    screen -S "$s" -X kill >/dev/null 2>&1 || true
    sleep 0.3
  fi
}

# FIX BUG-DELETE: run_slot now also writes OXTUNNEL_LOG so tail -f works
_run_slot() {
  local prof="$1" f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { _msg_warn "Profile not found: $prof"; return 1; }
  # shellcheck disable=SC1090
  source "$f"
  local s; s="$(_session_name "$prof")"
  local log_file="${LOG_DIR}/${prof}.log"
  mkdir -p "$LOG_DIR"
  # Cleanly stop any existing session first
  screen -S "$s" -X quit >/dev/null 2>&1 || true; sleep 0.2

  local ULIMIT_NOFILE="${ULIMIT_NOFILE:-1048576}"

  # Each case pipes printf into Python stdin; stdout+stderr → log file via OXTUNNEL_LOG
  if [[ "$ROLE" == "eu" ]]; then
    screen -dmS "$s" bash -lc \
      "ulimit -Hn ${ULIMIT_NOFILE} >/dev/null 2>&1 || true
       ulimit -Sn ${ULIMIT_NOFILE} >/dev/null 2>&1 || true
       printf '1\n%s\n%s\n%s\n' '${IRAN_IP}' '${BRIDGE}' '${SYNC}' \
       | PYTHONUNBUFFERED=1 OXTUNNEL_LOG='${log_file}' OXTUNNEL_POOL=\"\${OXTUNNEL_POOL:-0}\" \
         python3 '${PY}' >> '${log_file}' 2>&1"
  elif [[ "${AUTO_SYNC:-true}" == "true" ]]; then
    screen -dmS "$s" bash -lc \
      "ulimit -Hn ${ULIMIT_NOFILE} >/dev/null 2>&1 || true
       ulimit -Sn ${ULIMIT_NOFILE} >/dev/null 2>&1 || true
       printf '2\n%s\n%s\ny\n' '${BRIDGE}' '${SYNC}' \
       | PYTHONUNBUFFERED=1 OXTUNNEL_LOG='${log_file}' OXTUNNEL_POOL=\"\${OXTUNNEL_POOL:-0}\" \
         python3 '${PY}' >> '${log_file}' 2>&1"
  else
    screen -dmS "$s" bash -lc \
      "ulimit -Hn ${ULIMIT_NOFILE} >/dev/null 2>&1 || true
       ulimit -Sn ${ULIMIT_NOFILE} >/dev/null 2>&1 || true
       printf '2\n%s\n%s\nn\n%s\n' '${BRIDGE}' '${SYNC}' '${PORTS:-}' \
       | PYTHONUNBUFFERED=1 OXTUNNEL_LOG='${log_file}' OXTUNNEL_POOL=\"\${OXTUNNEL_POOL:-0}\" \
         python3 '${PY}' >> '${log_file}' 2>&1"
  fi
  _msg_ok "Started: ${B}$prof${R}"
}

_restart_slot() {
  _stop_slot "$1"; sleep 0.3; _run_slot "$1"
}

_get_slot_details() {
  local f="$CONF/${1}.env"
  [[ -f "$f" ]] || { echo "–"; return; }
  # shellcheck disable=SC1090
  local ROLE="" IRAN_IP="" BRIDGE="" SYNC="" AUTO_SYNC=""
  source "$f" 2>/dev/null || true
  if [[ "$ROLE" == "eu" ]]; then
    echo "→ ${IRAN_IP} | bridge:${BRIDGE} sync:${SYNC}"
  else
    echo "bridge:${BRIDGE} sync:${SYNC} autosync:${AUTO_SYNC:-true}"
  fi
}

# FIX BUG-LOGS: use tail -f on log file, NOT screen -r
# Ctrl+C only kills tail; the tunnel screen session keeps running
_logs_slot() {
  local prof="$1" log_file="${LOG_DIR}/${prof}.log"
  echo ""
  if [[ ! -f "$log_file" ]] || [[ ! -s "$log_file" ]]; then
    _msg_warn "No logs for '${prof}' yet."
    _msg_info "Start the tunnel first and wait a moment."
    pause; return
  fi
  _msg_info "Live log: ${B}$prof${R}  ${DIM}(Ctrl+C exits this view — tunnel stays running)${R}"
  _hr; echo ""
  # CRITICAL FIX: Ctrl+C only kills `tail`, NOT the screen/Python process
  trap '' INT
  tail -n 80 -f "$log_file" 2>/dev/null || true
  trap - INT
  echo ""; _msg_info "Log view ended. Tunnel is still running."
  pause
}

# FIX BUG-DELETE: require explicit 'yes' confirmation + wait for stop
_delete_slot() {
  local prof="$1" f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { _msg_warn "Profile '$prof' does not exist."; return 1; }
  echo ""
  _msg_warn "${RED}Delete '${B}${prof}${R}${RED}'? This cannot be undone.${R}"
  local confirm; read -r -p "  Type ${B}yes${R} to confirm: " confirm < /dev/tty
  [[ "$confirm" == "yes" ]] || { _msg_info "Cancelled."; return 0; }
  if _is_running "$prof"; then
    _msg_info "Stopping tunnel first..."
    _stop_slot "$prof"
  fi
  rm -f "$f" "${LOG_DIR}/${prof}.log"
  _msg_ok "Deleted: $prof"
}

_status_slot() {
  local prof="$1" f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { _msg_warn "Profile not found."; return 1; }
  # shellcheck disable=SC1090
  local ROLE="" IRAN_IP="" BRIDGE="" SYNC="" AUTO_SYNC="" PORTS=""
  source "$f" 2>/dev/null || true
  local st_c="$RED" st_i="○" st_t="Stopped"
  if _is_running "$prof"; then st_c="$GRN"; st_i="●"; st_t="Running"; fi
  echo ""
  echo -e "  ${CYN}Profile${R} : ${B}${prof}${R}  ${CYN}Role${R}: ${B}${ROLE^^}${R}"
  if [[ "$ROLE" == "eu" ]]; then
    echo -e "  ${CYN}Iran IP${R} : ${IRAN_IP:-–}"
    echo -e "  ${CYN}Bridge${R}  : ${BRIDGE:-–}   ${CYN}Sync${R}: ${SYNC:-–}"
  else
    echo -e "  ${CYN}Bridge${R}  : ${BRIDGE:-–}   ${CYN}Sync${R}: ${SYNC:-–}"
    echo -e "  ${CYN}AutoSync${R}: ${AUTO_SYNC:-true}${PORTS:+   Ports: $PORTS}"
  fi
  echo -e "  ${CYN}Status${R}  : ${st_c}${B}${st_i} ${st_t}${R}"
  echo ""
}

# ── Edit / create profile ─────────────────────────────────────
_edit_profile() {
  local prof="$1" role="${1%%[0-9]*}" f="$CONF/${prof}.env"
  echo ""
  echo -e "  ${CYN}${B}Configure:${R} ${B}$prof${R}  ${DIM}(role: ${role^^})${R}"
  _hr
  # Pre-fill from existing config if editing
  local ROLE="$role" IRAN_IP="" BRIDGE="" SYNC="" AUTO_SYNC="true" PORTS=""
  [[ -f "$f" ]] && { source "$f" 2>/dev/null || true; } || true

  if [[ "$role" == "eu" ]]; then
    IRAN_IP="$(_read_ip    "Iran server IP")"
    BRIDGE="$(_read_port   "Bridge port" "${BRIDGE:-7000}")"
    SYNC="$(_read_port     "Sync port  " "${SYNC:-7001}")"
    if [[ "$BRIDGE" == "$SYNC" ]]; then
      _msg_warn "Bridge and Sync ports must be different."; return 1
    fi
    cat > "$f" <<EOF
ROLE=eu
IRAN_IP=${IRAN_IP}
BRIDGE=${BRIDGE}
SYNC=${SYNC}
EOF
  else
    BRIDGE="$(_read_port "Bridge port" "${BRIDGE:-7000}")"
    SYNC="$(_read_port   "Sync port  " "${SYNC:-7001}")"
    if [[ "$BRIDGE" == "$SYNC" ]]; then
      _msg_warn "Bridge and Sync ports must be different."; return 1
    fi
    local as_choice; read -r -p "  Auto-Sync ports from EU? (Y/n): " as_choice < /dev/tty
    as_choice="${as_choice:-y}"
    if [[ "${as_choice,,}" == "y" ]]; then
      cat > "$f" <<EOF
ROLE=iran
BRIDGE=${BRIDGE}
SYNC=${SYNC}
AUTO_SYNC=true
PORTS=
EOF
    else
      local ports_raw; read -r -p "  Manual ports CSV (e.g. 80,443,2083): " ports_raw < /dev/tty
      PORTS="${ports_raw//[^0-9,]/}"
      cat > "$f" <<EOF
ROLE=iran
BRIDGE=${BRIDGE}
SYNC=${SYNC}
AUTO_SYNC=false
PORTS=${PORTS}
EOF
    fi
  fi
  _msg_ok "Saved: $f"
}

# ── Script management ─────────────────────────────────────────
_install_script() {
  _msg_info "Installing to: $INSTALL_PATH"
  mkdir -p "$(dirname "$INSTALL_PATH")"
  if [[ -f "$0" && "$0" != "bash" && "$0" != "/dev/fd/"* ]]; then
    cp -f "$0" "$INSTALL_PATH"
  else
    fetch_url_to "$SELF_URL" "$INSTALL_PATH"
  fi
  chmod +x "$INSTALL_PATH"
  _msg_ok "Installed. Run: sudo ox-tunnle"
}

_update_script() {
  _msg_info "Updating from: $SELF_URL"
  local tmp; tmp="$(mktemp)"
  fetch_url_to "$SELF_URL" "$tmp"
  [[ -s "$tmp" ]] || { _msg_err "Update failed: empty download."; rm -f "$tmp"; return 1; }
  head -n 1 "$tmp" | grep -qE "^#!.*bash" || {
    _msg_err "Update failed: not a valid bash script."; rm -f "$tmp"; return 1
  }
  chmod +x "$tmp"
  if is_installed; then
    mv -f "$tmp" "$INSTALL_PATH"; chmod +x "$INSTALL_PATH"
    _msg_ok "Updated. Run: sudo ox-tunnle"
  else
    mv -f "$tmp" "./${SCRIPT_FILENAME}"; chmod +x "./${SCRIPT_FILENAME}"
    _msg_ok "Saved locally: ./${SCRIPT_FILENAME}"
  fi
}

_uninstall_script() {
  _disable_cron >/dev/null 2>&1 || true
  rm -f "$HC_SCRIPT" "$INSTALL_PATH"
  _msg_ok "Uninstalled."
}

_optimize_server() {
  echo ""; _msg_info "Enabling BBR and applying sysctl tuning..."
  have sysctl   || apt_try_install procps
  have modprobe || apt_try_install kmod
  modprobe tcp_bbr >/dev/null 2>&1 || true
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    sysctl -w net.core.default_qdisc=fq          >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    cat > /etc/sysctl.d/99-ox-tunnle.conf <<'EOF'
# Ox Tunnle — network tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true
    _msg_ok "BBR active. cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  else
    _msg_warn "BBR unavailable on this kernel. Upgrade kernel to use BBR."
  fi
}

# ── Cron / health-check ───────────────────────────────────────
_disable_cron() {
  local tmp; tmp="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -vF "$HC_CRON_TAG" > "$tmp" || true
  crontab "$tmp" || true; rm -f "$tmp"
  _msg_ok "Cron health-check disabled."
}

_install_hc_script() {
  cat > "$HC_SCRIPT" <<'HCEOF'
#!/usr/bin/env bash
set -euo pipefail
HCEOF
  # append variable values that need expansion at install time
  cat >> "$HC_SCRIPT" <<EOF
PY="${PY}"
CONF="${CONF}"
LOG_DIR="${LOG_DIR}"
MAX="${MAX}"
EOF
  cat >> "$HC_SCRIPT" <<'HCEOF'
session_name(){ echo "ox_tunnle_$1"; }
is_running(){ local s; s="$(session_name "$1")"; screen -ls 2>/dev/null | grep -qF "$s"; }
start_from_profile(){
  local prof="$1" f="${CONF}/${prof}.env"
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC1090
  source "$f"
  local s; s="$(session_name "$prof")"
  local log_file="${LOG_DIR}/${prof}.log"
  mkdir -p "$LOG_DIR"
  screen -S "$s" -X quit >/dev/null 2>&1 || true; sleep 0.2
  if [[ "${ROLE}" == "eu" ]]; then
    screen -dmS "$s" bash -lc \
      "ulimit -Hn 1048576 >/dev/null 2>&1||true; ulimit -Sn 1048576 >/dev/null 2>&1||true
       printf '1\n%s\n%s\n%s\n' '${IRAN_IP}' '${BRIDGE}' '${SYNC}' \
       | PYTHONUNBUFFERED=1 OXTUNNEL_LOG='${log_file}' OXTUNNEL_POOL=\"${OXTUNNEL_POOL:-0}\" \
         python3 '${PY}' >> '${log_file}' 2>&1"
  elif [[ "${AUTO_SYNC:-true}" == "true" ]]; then
    screen -dmS "$s" bash -lc \
      "ulimit -Hn 1048576 >/dev/null 2>&1||true; ulimit -Sn 1048576 >/dev/null 2>&1||true
       printf '2\n%s\n%s\ny\n' '${BRIDGE}' '${SYNC}' \
       | PYTHONUNBUFFERED=1 OXTUNNEL_LOG='${log_file}' OXTUNNEL_POOL=\"${OXTUNNEL_POOL:-0}\" \
         python3 '${PY}' >> '${log_file}' 2>&1"
  else
    screen -dmS "$s" bash -lc \
      "ulimit -Hn 1048576 >/dev/null 2>&1||true; ulimit -Sn 1048576 >/dev/null 2>&1||true
       printf '2\n%s\n%s\nn\n%s\n' '${BRIDGE}' '${SYNC}' '${PORTS:-}' \
       | PYTHONUNBUFFERED=1 OXTUNNEL_LOG='${log_file}' OXTUNNEL_POOL=\"${OXTUNNEL_POOL:-0}\" \
         python3 '${PY}' >> '${log_file}' 2>&1"
  fi
}
[[ -f "$PY" ]] || exit 0
for role in eu iran; do
  for i in $(seq 1 "$MAX"); do
    prof="${role}${i}"
    [[ -f "${CONF}/${prof}.env" ]] || continue
    is_running "$prof" || start_from_profile "$prof" >/dev/null 2>&1 || true
  done
done
HCEOF
  chmod +x "$HC_SCRIPT"
}

_enable_cron() {
  _install_hc_script
  echo ""
  local interval; read -r -p "  Health-check interval in minutes [1]: " interval < /dev/tty || true
  interval="${interval:-1}"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=1
  [[ "$interval" -ge 1 ]] || interval=1
  local line="*/${interval} * * * * ${HC_SCRIPT} >/dev/null 2>&1 ${HC_CRON_TAG}"
  local tmp; tmp="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -vF "$HC_CRON_TAG" > "$tmp" || true
  echo "$line" >> "$tmp"; crontab "$tmp"; rm -f "$tmp"
  _msg_ok "Cron enabled: every ${interval} minute(s)."
}

# ── Banner ────────────────────────────────────────────────────
_print_banner() {
  local loc; loc="$(_get_location)"
  local dc;  dc="$(_get_datacenter)"
  local inst_c="$RED" inst_t="NOT INSTALLED"
  if is_installed; then inst_c="$GRN"; inst_t="INSTALLED"; fi

  clear || true
  _dhr
  echo -e "  ${CYN}${B}  🐂  ${WHT}OX TUNNLE${R}  ${DIM}v${VERSION}${R}   ${CYN}${DIM}${TG_CHANNEL}${R}"
  _dhr
  echo -e "  ${DIM}📍 ${loc}${R}"
  echo -e "  ${DIM}🏢 ${dc}${R}"
  echo -e "  ${inst_c}${B}●${R} ${inst_c}${inst_t}${R}"
  _dhr
  echo ""
}

# ── Profile picker helpers ────────────────────────────────────

# Returns list of all saved profiles (both roles, all slots)
_list_saved_profiles() {
  local list=()
  for role in eu iran; do
    for i in $(seq 1 "$MAX"); do
      local prof="${role}${i}"
      [[ -f "$CONF/${prof}.env" ]] && list+=("$prof")
    done
  done
  echo "${list[@]:-}"
}

# Print numbered list of ALL slots grouped by role (EU 1-10, IRAN 11-20)
_print_all_slots() {
  local n=0

  # ── EU Servers (slots 1-10) ──
  echo ""
  echo -e "  ${CYN}${B}┌─────────────────────────────────────┐${R}"
  echo -e "  ${CYN}${B}│   🌍  EU SERVERS  (slots 1 – 10)    │${R}"
  echo -e "  ${CYN}${B}└─────────────────────────────────────┘${R}"
  echo -e "  ${DIM}  #   Name        Status${R}"
  _hr
  for i in $(seq 1 "$MAX"); do
    local prof="eu${i}"
    n=$((n + 1))
    local st_c="$DIM" st_t="(empty)"
    if [[ -f "$CONF/${prof}.env" ]]; then
      st_c="$YLW"; st_t="saved"
      if _is_running "$prof"; then st_c="$GRN"; st_t="● running"; fi
    fi
    printf "  ${CYN}${B}%3s${R}   %-12s${st_c}%s${R}\n" "$n" "$prof" "$st_t"
  done
  _hr

  # ── IRAN Servers (slots 11-20) ──
  echo ""
  echo -e "  ${CYN}${B}┌─────────────────────────────────────┐${R}"
  echo -e "  ${CYN}${B}│   🇮🇷  IRAN SERVERS  (slots 11 – 20) │${R}"
  echo -e "  ${CYN}${B}└─────────────────────────────────────┘${R}"
  echo -e "  ${DIM}  #   Name        Status${R}"
  _hr
  for i in $(seq 1 "$MAX"); do
    local prof="iran${i}"
    n=$((n + 1))
    local st_c="$DIM" st_t="(empty)"
    if [[ -f "$CONF/${prof}.env" ]]; then
      st_c="$YLW"; st_t="saved"
      if _is_running "$prof"; then st_c="$GRN"; st_t="● running"; fi
    fi
    printf "  ${CYN}${B}%3s${R}   %-12s${st_c}%s${R}\n" "$n" "$prof" "$st_t"
  done
  _hr
}

# Print numbered list of ONLY saved profiles for manage
_print_saved_profiles() {
  local profs=()
  for role in eu iran; do
    for i in $(seq 1 "$MAX"); do
      local prof="${role}${i}"
      [[ -f "$CONF/${prof}.env" ]] && profs+=("$prof")
    done
  done
  if [[ ${#profs[@]} -eq 0 ]]; then
    echo ""; _msg_info "No saved profiles. Create one first."; echo ""; return 1
  fi
  echo ""
  echo -e "  ${DIM}  #  Name      Role   Status   Details${R}"
  _hr
  local n=0
  for prof in "${profs[@]}"; do
    n=$((n + 1))
    local role="${prof%%[0-9]*}"
    local st_c="$RED" st_t="Stopped"
    if _is_running "$prof"; then st_c="$GRN"; st_t="Running"; fi
    local details; details="$(_get_slot_details "$prof")"
    printf "  ${CYN}${B}%3s${R}  %-10s%-7s${st_c}%-10s${R}${DIM}%s${R}\n" \
      "$n" "$prof" "${role^^}" "$st_t" "$details"
  done
  _hr
  return 0
}

# Resolve slot number → profile name (all 20 slots)
_slot_num_to_prof() {
  local n="$1" nn=0
  for role in eu iran; do
    for i in $(seq 1 "$MAX"); do
      nn=$((nn + 1))
      if [[ "$nn" -eq "$n" ]]; then echo "${role}${i}"; return; fi
    done
  done
  echo ""
}

# Resolve saved-profile index → profile name
_saved_idx_to_prof() {
  local n="$1" nn=0
  for role in eu iran; do
    for i in $(seq 1 "$MAX"); do
      local prof="${role}${i}"
      [[ -f "$CONF/${prof}.env" ]] || continue
      nn=$((nn + 1))
      if [[ "$nn" -eq "$n" ]]; then echo "$prof"; return; fi
    done
  done
  echo ""
}

# ════════════════════════════════════════════════════════════
#  MENUS
# ════════════════════════════════════════════════════════════

# ── Manage single slot ────────────────────────────────────────
_manage_slot_menu() {
  local prof="$1"
  while true; do
    clear || true
    _dhr
    echo -e "  ${CYN}${B}  ⚙  MANAGE TUNNEL${R}  ${DIM}— $prof${R}"
    _dhr
    _status_slot "$prof"
    _section "ACTIONS"
    _menu_item "1" "▶  Start"
    _menu_item "2" "⏹  Stop"
    _menu_item "3" "↺  Restart"
    _section "INFO"
    _menu_item "4" "📊  Show Config"
    _menu_item "5" "📜  View Live Log"
    _section "CONFIG"
    _menu_item "6" "✏   Edit Profile"
    _menu_item "7" "🗑   Delete Slot"
    echo ""
    _hr
    _menu_item "0" "◀  Back"
    _hr; echo ""
    local choice; read -r -p "  Select: " choice < /dev/tty
    case "$choice" in
      1) echo ""; _run_slot "$prof"; pause ;;
      2) echo ""; _stop_slot "$prof"; _msg_ok "Stopped."; pause ;;
      3) echo ""; _restart_slot "$prof"; pause ;;
      4) _status_slot "$prof"; pause ;;
      5) _logs_slot "$prof" ;;
      6) _edit_profile "$prof"; pause ;;
      7) _delete_slot "$prof"; pause; return ;;  # return after delete
      0) return ;;
      *) _msg_warn "Invalid option."; sleep 0.8 ;;
    esac
  done
}

# ── New / Edit profile ────────────────────────────────────────
_new_profile_menu() {
  while true; do
    clear || true
    _dhr
    echo -e "  ${CYN}${B}  ➕  NEW / EDIT PROFILE${R}"
    _dhr
    echo -e "  ${DIM}  Choose a slot number to create or edit a tunnel profile.${R}"
    _print_all_slots
    echo ""
    _menu_item "0" "◀  Back"
    _hr; echo ""
    local choice; read -r -p "  Enter slot number (1-20) or 0 to go back: " choice < /dev/tty
    [[ "$choice" =~ ^[0-9]+$ ]] || { _msg_warn "Please enter a number."; sleep 0.8; continue; }
    [[ "$choice" -eq 0 ]] && return
    [[ "$choice" -ge 1 && "$choice" -le 20 ]] || { _msg_warn "Enter a number between 1 and 20."; sleep 0.8; continue; }
    local prof; prof="$(_slot_num_to_prof "$choice")"
    [[ -n "$prof" ]] || { _msg_warn "Slot not found."; sleep 0.8; continue; }
    _edit_profile "$prof"
    pause
  done
}

# ── Manage tunnels (saved only) ───────────────────────────────
_manage_tunnels_menu() {
  while true; do
    clear || true
    _dhr
    echo -e "  ${CYN}${B}  📋  MANAGE TUNNELS${R}"
    _dhr
    _print_saved_profiles || { pause; return; }
    echo ""
    _menu_item "0" "◀  Back"
    _hr; echo ""
    local choice; read -r -p "  Select tunnel number or 0: " choice < /dev/tty
    [[ "$choice" =~ ^[0-9]+$ ]] || { _msg_warn "Enter a number."; sleep 0.8; continue; }
    [[ "$choice" -eq 0 ]] && return
    local prof; prof="$(_saved_idx_to_prof "$choice")"
    [[ -n "$prof" ]] || { _msg_warn "Invalid selection."; sleep 0.8; continue; }
    _manage_slot_menu "$prof"
  done
}

# ── All status overview ───────────────────────────────────────
_all_status_menu() {
  clear || true
  _dhr
  echo -e "  ${CYN}${B}  📊  ALL TUNNEL STATUS${R}"
  _dhr
  local found=0
  for role in eu iran; do
    for i in $(seq 1 "$MAX"); do
      local prof="${role}${i}"
      [[ -f "$CONF/${prof}.env" ]] || continue
      found=1
      _status_slot "$prof"
      _hr
    done
  done
  if [[ $found -eq 0 ]]; then echo ""; _msg_info "No saved profiles found."; echo ""; fi
  pause
}

# ── Cron menu ─────────────────────────────────────────────────
_cron_menu() {
  while true; do
    clear || true
    _dhr
    echo -e "  ${CYN}${B}  ⏰  CRON HEALTH-CHECK${R}"
    _dhr
    echo -e "  ${DIM}Auto-restart tunnels if they stop unexpectedly.${R}"
    echo ""
    # Show current cron state
    if crontab -l 2>/dev/null | grep -qF "$HC_CRON_TAG"; then
      _msg_ok "Cron is ${GRN}ENABLED${R}"
      echo -e "  ${DIM}$(crontab -l 2>/dev/null | grep "$HC_CRON_TAG")${R}"
    else
      _msg_warn "Cron is ${RED}DISABLED${R}"
    fi
    echo ""
    _section "OPTIONS"
    _menu_item "1" "Enable / Update cron"
    _menu_item "2" "Disable cron"
    echo ""
    _hr
    _menu_item "0" "◀  Back"
    _hr; echo ""
    local choice; read -r -p "  Select: " choice < /dev/tty
    case "$choice" in
      1) _enable_cron; pause ;;
      2) _disable_cron; pause ;;
      0) return ;;
      *) _msg_warn "Invalid option."; sleep 0.8 ;;
    esac
  done
}

# ── Script menu ───────────────────────────────────────────────
_script_menu() {
  while true; do
    clear || true
    _dhr
    echo -e "  ${CYN}${B}  🔧  SCRIPT MANAGEMENT${R}"
    _dhr
    echo ""
    _menu_item "1" "📥  Install system-wide  ${DIM}(→ /usr/local/bin/ox-tunnle)${R}"
    _menu_item "2" "🔄  Update script from GitHub"
    _menu_item "3" "🗑   Uninstall script"
    echo ""
    _hr
    _menu_item "0" "◀  Back"
    _hr; echo ""
    local choice; read -r -p "  Select: " choice < /dev/tty
    case "$choice" in
      1) echo ""; _install_script; pause ;;
      2) echo ""; _update_script; pause ;;
      3)
        echo ""
        _msg_warn "Uninstall will remove ox-tunnle from system. Tunnels keep running."
        local c; read -r -p "  Confirm (yes/N): " c < /dev/tty
        if [[ "$c" == "yes" ]]; then _uninstall_script; pause; return; else _msg_info "Cancelled."; fi
        pause ;;
      0) return ;;
      *) _msg_warn "Invalid option."; sleep 0.8 ;;
    esac
  done
}

# ════════════════════════════════════════════════════════════
#  MAIN MENU
# ════════════════════════════════════════════════════════════
_main_menu() {
  while true; do
    _print_banner

    _section "TUNNEL MANAGEMENT"
    _menu_item "1" "➕  New / Edit Profile"
    _menu_item "2" "📋  Manage Tunnels"
    _menu_item "3" "📊  All Tunnel Status"

    _section "SYSTEM"
    _menu_item "4" "⏰  Cron Health-Check"
    _menu_item "5" "🚀  Optimize Server  ${DIM}(BBR + sysctl)${R}"

    _section "SCRIPT"
    _menu_item "6" "🔧  Script Management"

    echo ""
    _hr
    _menu_item "0" "🚪  Exit"
    _hr; echo ""

    local choice; read -r -p "  Select: " choice < /dev/tty
    case "$choice" in
      1) _new_profile_menu ;;
      2) _manage_tunnels_menu ;;
      3) _all_status_menu ;;
      4) _cron_menu ;;
      5) echo ""; _optimize_server; pause ;;
      6) _script_menu ;;
      0) echo ""; _msg_info "Goodbye."; echo ""; exit 0 ;;
      *) _msg_warn "Invalid option."; sleep 0.8 ;;
    esac
  done
}

# ════════════════════════════════════════════════════════════
#  ENTRY POINT
# ════════════════════════════════════════════════════════════
need_root
ensure
_main_menu

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


# ── Safe profile loader (NEVER uses 'source') ─────────────────
# Reads key=value pairs line by line without executing any code.
# Immune to set -euo pipefail + unquoted values with spaces.
# Call: _load_profile "$f"
# Sets: ROLE IRAN_IP BRIDGE SYNC AUTO_SYNC PORTS LABEL
_load_profile() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  # Reset all expected variables first
  ROLE="" IRAN_IP="" BRIDGE="" SYNC="" AUTO_SYNC="true" PORTS="" LABEL="" SECRET=""
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # skip blank lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # match KEY=VALUE (value may or may not be quoted)
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # strip surrounding double/single quotes
      val="${val#\"}" ; val="${val%\"}"
      val="${val#\'}" ; val="${val%\'}"
      printf -v "$key" '%s' "$val"
    fi
  done < "$f"
}

_install_systemd_service() {
  if ! command -v systemctl >/dev/null 2>&1; then return 0; fi
  local unit_file="/etc/systemd/system/ox-tunnle@.service"
  if [[ ! -f "$unit_file" ]]; then
    cat > "$unit_file" <<EOF
[Unit]
Description=Ox Tunnle Service (%I)
After=network-online.target sysctl.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CONF}/%i.env
Environment="ULIMIT_NOFILE=1048576"
LimitNOFILE=1048576
LimitNPROC=1048576
ExecStart=/usr/bin/env python3 "${PY}"
Restart=always
RestartSec=3s
KillMode=mixed
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

ensure() {
  mkdir -p "$CONF" "$LOG_DIR" "$(dirname "$PY")"
  have python3 || apt_try_install python3
  _install_systemd_service
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

# ── Network info  (instant cache with async update to eliminate menu lag) ───────
_CACHE_IP=""
_CACHE_LOC=""
_CACHE_DC=""
_CACHE_READY=0

_fetch_server_info() {
  local cache_file="/tmp/.oxtunnel_server_info.cache"
  if [[ -f "$cache_file" && -s "$cache_file" ]]; then
    # shellcheck disable=SC1090
    source "$cache_file" 2>/dev/null || true
    _CACHE_IP="${_CACHE_IP:-Unknown}"
    _CACHE_LOC="${_CACHE_LOC:-Unknown}"
    _CACHE_DC="${_CACHE_DC:-Unknown}"
    _CACHE_READY=1
    return 0
  fi

  # Instant fallbacks to prevent terminal blocking on menu load
  _CACHE_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'Fetching...')"
  _CACHE_LOC="Fetching..."
  _CACHE_DC="Fetching..."
  _CACHE_READY=1

  # Fetch asynchronously in background with strict timeouts
  (
    local ip city country org json
    ip="$(curl -fsSL --max-time 2 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      json="$(curl -fsSL --max-time 2 "https://ipinfo.io/${ip}/json" 2>/dev/null || true)"
      if [[ -n "$json" ]]; then
        city="$(echo "$json" | tr -d '\n' | sed -n 's/.*"city":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
        country="$(echo "$json" | tr -d '\n' | sed -n 's/.*"country":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
        org="$(echo "$json" | tr -d '\n' | sed -n 's/.*"org":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      fi
      cat > "$cache_file" <<EOF
_CACHE_IP="${ip}"
_CACHE_LOC="${city}${city:+, }${country:-Unknown}"
_CACHE_DC="${org:-Unknown}"
EOF
    fi
  ) >/dev/null 2>&1 &
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

# ── Session management (Systemd integrated, replacing screen) ────────
_session_name() { echo "ox_tunnle_$1"; }

_is_running() {
  local prof="$1"
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl is-active --quiet "ox-tunnle@${prof}.service" 2>/dev/null
  else
    pgrep -f "OXTUNNEL_PROFILE=${prof}.*${PY}" >/dev/null 2>&1
  fi
}

_stop_slot() {
  local prof="$1"
  _is_running "$prof" || { return 0; }
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl stop "ox-tunnle@${prof}.service" >/dev/null 2>&1 || true
    systemctl disable "ox-tunnle@${prof}.service" >/dev/null 2>&1 || true
  else
    pkill -f "OXTUNNEL_PROFILE=${prof}.*${PY}" >/dev/null 2>&1 || true
    sleep 0.5
    pkill -9 -f "OXTUNNEL_PROFILE=${prof}.*${PY}" >/dev/null 2>&1 || true
  fi
}

_run_slot() {
  local prof="$1" f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { _msg_warn "Profile not found: $prof"; return 1; }
  _load_profile "$f"
  local log_file="${LOG_DIR}/${prof}.log"
  mkdir -p "$LOG_DIR"
  _stop_slot "$prof" >/dev/null 2>&1 || true; sleep 0.2

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    _install_systemd_service
    systemctl enable --now "ox-tunnle@${prof}.service" >/dev/null 2>&1
  else
    # Non-systemd fallback using background invocation
    (
      export ROLE IRAN_IP BRIDGE SYNC AUTO_SYNC PORTS LABEL SECRET
      export ULIMIT_NOFILE="${ULIMIT_NOFILE:-1048576}" OXTUNNEL_LOG="${log_file}" OXTUNNEL_PROFILE="${prof}"
      ulimit -Hn "${ULIMIT_NOFILE}" >/dev/null 2>&1 || true
      ulimit -Sn "${ULIMIT_NOFILE}" >/dev/null 2>&1 || true
      nohup python3 "${PY}" >> "${log_file}" 2>&1 &
    ) >/dev/null 2>&1
  fi
  _msg_ok "Started: ${B}$prof${R}"
}

_restart_slot() {
  _stop_slot "$1"; sleep 0.3; _run_slot "$1"
}

_get_slot_details() {
  local f="$CONF/${1}.env"
  [[ -f "$f" ]] || { echo "–"; return; }
  local ROLE="" IRAN_IP="" BRIDGE="" SYNC="" AUTO_SYNC="" LABEL="" SECRET=""
  _load_profile "$f"
  local sec_tag="${SECRET:+ [Auth:ON]}"
  if [[ "$ROLE" == "eu" ]]; then
    echo "Iran:${IRAN_IP:-?} B:${BRIDGE:-7000} S:${SYNC:-7001}${sec_tag}"
  else
    if [[ "${AUTO_SYNC:-true}" == "true" ]]; then
      echo "B:${BRIDGE:-7000} S:${SYNC:-7001} (AutoSync)${sec_tag}"
    else
      echo "B:${BRIDGE:-7000} S:${SYNC:-7001} Ports:${PORTS:-}${sec_tag}"
    fi
  fi
}

_view_logs() {
  local prof="$1" log_file="${LOG_DIR}/${prof}.log"
  echo ""
  if [[ ! -f "$log_file" ]] || [[ ! -s "$log_file" ]]; then
    _msg_warn "No logs for '${prof}' yet."
    _msg_info "Start the tunnel first and wait a moment."
    pause; return
  fi
  _msg_info "Live log: ${B}$prof${R}  ${DIM}(Ctrl+C exits this view — tunnel stays running)${R}"
  _hr; echo ""
  # CRITICAL FIX: trap ':' catches INT in bash (so script doesn't exit) 
  # but allows child 'tail' to receive default SIGINT and terminate.
  trap ':' INT
  tail -n 80 -f "$log_file" 2>/dev/null || true
  trap - INT
  echo ""; _msg_info "Log view ended. Tunnel is still running."
  # Remove pause so it returns immediately to the slot management menu
}

# FIX BUG-DELETE: require explicit 'yes' confirmation + wait for stop
_delete_slot() {
  local prof="$1" f="$CONF/${prof}.env"
  [[ -f "$f" ]] || { _msg_warn "Profile '$prof' does not exist."; return 1; }
  echo ""
  _msg_warn "${RED}Delete '${B}${prof}${R}${RED}'? This cannot be undone.${R}"
  echo ""
  read -r -p "  Type 'yes' to confirm: " confirm < /dev/tty || confirm=""
  # Trim all whitespace and convert to lowercase for comparison
  confirm="$(echo "$confirm" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  if [[ "$confirm" != "yes" ]]; then
    _msg_info "Cancelled."
    return 0
  fi
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
  local ROLE="" IRAN_IP="" BRIDGE="" SYNC="" AUTO_SYNC="" PORTS="" LABEL="" SECRET=""
  _load_profile "$f"
  local st_c="$RED" st_i="○" st_t="Stopped"
  if _is_running "$prof"; then st_c="$GRN"; st_i="●"; st_t="Running"; fi
  echo ""
  echo -e "  ${CYN}Profile${R} : ${B}${prof}${R}  ${CYN}Role${R}: ${B}${ROLE^^}${R}"
  # Only show Label line if set (no inline duplicate)
  if [[ -n "$LABEL" ]]; then
    echo -e "  ${CYN}Label${R}   : ${B}${LABEL}${R}"
  fi
  if [[ "$ROLE" == "eu" ]]; then
    echo -e "  ${CYN}Iran IP${R} : ${IRAN_IP:-–}"
    echo -e "  ${CYN}Bridge${R}  : ${BRIDGE:-–}   ${CYN}Sync${R}: ${SYNC:-–}"
  else
    echo -e "  ${CYN}Bridge${R}  : ${BRIDGE:-–}   ${CYN}Sync${R}: ${SYNC:-–}"
    echo -e "  ${CYN}AutoSync${R}: ${AUTO_SYNC:-true}${PORTS:+   Ports: $PORTS}"
  fi
  if [[ -n "$SECRET" ]]; then
    echo -e "  ${CYN}Auth Token${R}: ${GRN}Enabled (${SECRET:0:8}...)${R}"
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
  local ROLE="$role" IRAN_IP="" BRIDGE="" SYNC="" AUTO_SYNC="true" PORTS="" LABEL="" SECRET=""
  [[ -f "$f" ]] && _load_profile "$f" || true

  local label_raw
  read -r -p "  Tunnel Label/Name (optional, press Enter to keep '${LABEL:-none}'): " label_raw < /dev/tty || true
  if [[ -n "$label_raw" ]]; then
    LABEL="$(echo "$label_raw" | tr -d '"'\''\\' | cut -c1-30)"
  fi

  local sec_raw=""
  read -r -p "  Security Secret Token (optional, Enter to keep '${SECRET:-none}', 'auto' for random hex token): " sec_raw < /dev/tty || true
  if [[ "${sec_raw,,}" == "auto" ]]; then
    SECRET="$(head -c 16 /dev/urandom | md5sum <<< "$RANDOM-$(date)" | awk '{print $1}' 2>/dev/null || printf "%032x" "${RANDOM}")"
  elif [[ -n "$sec_raw" ]]; then
    if [[ "${sec_raw,,}" == "none" || "${sec_raw,,}" == "clear" ]]; then
      SECRET=""
    else
      SECRET="$(echo "$sec_raw" | tr -d '"'\''\\' | cut -c1-64)"
    fi
  fi

  if [[ "$role" == "eu" ]]; then
    IRAN_IP="$(_read_ip    "Iran server IP")"
    BRIDGE="$(_read_port   "Bridge port" "${BRIDGE:-7000}")"
    SYNC="$(_read_port     "Sync port  " "${SYNC:-7001}")"
    if [[ "$BRIDGE" == "$SYNC" ]]; then
      _msg_warn "Bridge and Sync ports must be different."; return 1
    fi
    cat > "$f" <<EOF
ROLE=eu
LABEL="${LABEL}"
IRAN_IP="${IRAN_IP}"
BRIDGE=${BRIDGE}
SYNC=${SYNC}
SECRET="${SECRET}"
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
LABEL="${LABEL}"
BRIDGE=${BRIDGE}
SYNC=${SYNC}
AUTO_SYNC=true
PORTS=
SECRET="${SECRET}"
EOF
    else
      local ports_raw; read -r -p "  Manual ports CSV (e.g. 80,443,2083): " ports_raw < /dev/tty
      PORTS="${ports_raw//[^0-9,]/}"
      cat > "$f" <<EOF
ROLE=iran
LABEL="${LABEL}"
BRIDGE=${BRIDGE}
SYNC=${SYNC}
AUTO_SYNC=false
PORTS="${PORTS}"
SECRET="${SECRET}"
EOF
    fi
  fi
  _msg_ok "Saved: $f"
}

_rename_label() {
  local prof="$1" f="$CONF/${prof}.env"
  [[ -f "$f" ]] || return 1
  local LABEL=""
  _load_profile "$f"
  echo ""
  _msg_info "Current Label for '${prof}': ${LABEL:-none}"
  local new_label
  read -r -p "  Enter new label (or type 'clear' to remove): " new_label < /dev/tty || true
  if [[ "${new_label,,}" == "clear" ]]; then
    new_label=""
  else
    # Sanitize: remove quotes and backslashes, cap at 30 chars
    new_label="$(echo "$new_label" | tr -d '"'\''\\'  | cut -c1-30)"
  fi

  # Use a temp file to avoid sed special-character injection
  local tmp; tmp="$(mktemp)"
  if grep -q "^LABEL=" "$f"; then
    grep -v "^LABEL=" "$f" > "$tmp"
  else
    cp "$f" "$tmp"
  fi
  echo "LABEL=\"${new_label}\"" >> "$tmp"
  mv "$tmp" "$f"
  _msg_ok "Label updated for $prof"
}

# ── Script management ─────────────────────────────────────────
_install_script() {
  _msg_info "Installing bash script to: $INSTALL_PATH"
  mkdir -p "$(dirname "$INSTALL_PATH")" "$(dirname "$PY")"
  if [[ -f "$0" && "$0" != "bash" && "$0" != "/dev/fd/"* ]]; then
    cp -f "$0" "$INSTALL_PATH"
  else
    fetch_url_to "$SELF_URL" "$INSTALL_PATH"
  fi
  chmod +x "$INSTALL_PATH"

  _msg_info "Installing python core to: $PY"
  fetch_url_to "$PY_URL" "$PY"
  chmod +x "$PY"
  _msg_ok "Installed. Run: sudo ox-tunnle"
}

_update_script() {
  _msg_info "Updating bash script & python core from GitHub..."
  local tmp; tmp="$(mktemp)"
  fetch_url_to "$SELF_URL" "$tmp"
  [[ -s "$tmp" ]] || { _msg_err "Update failed: empty download for $SCRIPT_FILENAME."; rm -f "$tmp"; return 1; }
  head -n 1 "$tmp" | grep -qE "^#!.*bash" || {
    _msg_err "Update failed: not a valid bash script."; rm -f "$tmp"; return 1
  }

  local tmp_py; tmp_py="$(mktemp)"
  fetch_url_to "$PY_URL" "$tmp_py"
  [[ -s "$tmp_py" ]] || { _msg_err "Update failed: empty download for ox-tunnle.py."; rm -f "$tmp" "$tmp_py"; return 1; }

  chmod +x "$tmp" "$tmp_py"
  mkdir -p "$(dirname "$PY")"
  mv -f "$tmp_py" "$PY"
  chmod +x "$PY"

  if is_installed; then
    mv -f "$tmp" "$INSTALL_PATH"; chmod +x "$INSTALL_PATH"
    _msg_ok "Updated successfully. Run: sudo ox-tunnle"
  else
    mv -f "$tmp" "./${SCRIPT_FILENAME}"; chmod +x "./${SCRIPT_FILENAME}"
    _msg_ok "Updated local file and $PY successfully."
  fi
}

_uninstall_script() {
  _disable_cron >/dev/null 2>&1 || true
  rm -f "$HC_SCRIPT" "$INSTALL_PATH" "$PY"
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
# Ox Tunnle — low-latency + high-throughput network tuning

# ── Congestion control (BBR = good throughput without bufferbloat)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# ── Socket buffers — match Python SOCKBUF = 4 MB
#    (large enough for throughput, small enough to avoid bufferbloat)
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.ipv4.tcp_rmem=4096 262144 8388608
net.ipv4.tcp_wmem=4096 262144 8388608

# ── ACK behaviour — send ACKs immediately (no delayed-ACK buildup)
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_window_scaling=1

# ── Connection handling — handle large bursts gracefully
net.core.netdev_max_backlog=65536
net.ipv4.tcp_max_syn_backlog=65536
net.core.somaxconn=65536

# ── Latency tuning
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_fin_timeout=15
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
is_running(){
  local prof="$1"
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl is-active --quiet "ox-tunnle@${prof}.service" 2>/dev/null
  else
    pgrep -f "OXTUNNEL_PROFILE=${prof}.*${PY}" >/dev/null 2>&1
  fi
}
start_from_profile(){
  local prof="$1" f="${CONF}/${prof}.env"
  [[ -f "$f" ]] || return 0
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl enable --now "ox-tunnle@${prof}.service" >/dev/null 2>&1 || true
  else
    local ROLE="" IRAN_IP="" BRIDGE="" SYNC="" AUTO_SYNC="true" PORTS="" LABEL="" SECRET=""
    local _line _key _val
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      [[ -z "$_line" || "$_line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        _key="${BASH_REMATCH[1]}"; _val="${BASH_REMATCH[2]}"
        _val="${_val#\"}" ; _val="${_val%\"}"
        _val="${_val#\'}" ; _val="${_val%\'}"
        printf -v "$_key" '%s' "$_val"
      fi
    done < "$f"
    local log_file="${LOG_DIR}/${prof}.log"
    mkdir -p "$LOG_DIR"
    pkill -f "OXTUNNEL_PROFILE=${prof}.*${PY}" >/dev/null 2>&1 || true; sleep 0.2
    (
      export ROLE IRAN_IP BRIDGE SYNC AUTO_SYNC PORTS LABEL SECRET
      export ULIMIT_NOFILE="${ULIMIT_NOFILE:-1048576}" OXTUNNEL_LOG="${log_file}" OXTUNNEL_PROFILE="${prof}"
      ulimit -Hn 1048576 >/dev/null 2>&1 || true; ulimit -Sn 1048576 >/dev/null 2>&1 || true
      nohup python3 "${PY}" >> "${log_file}" 2>&1 &
    ) >/dev/null 2>&1
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

# ── Banner  (reads from cache — zero network delay) ──────────
_print_banner() {
  local loc="${_CACHE_LOC:-…}"
  local dc="${_CACHE_DC:-…}"
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
  echo -e "  ${CYN}${B}┌───────────────────────────────────────────────┐${R}"
  echo -e "  ${CYN}${B}│   🌍  EU SERVERS  (slots 1 – 10)              │${R}"
  echo -e "  ${CYN}${B}└───────────────────────────────────────────────┘${R}"
  echo -e "  ${DIM}  #   Name        Label                 Status${R}"
  _hr
  for i in $(seq 1 "$MAX"); do
    local prof="eu${i}"
    n=$((n + 1))
    # Read label in a subshell to avoid polluting globals across iterations
    local lbl st_c="$DIM" st_t="(empty)"
    if [[ -f "$CONF/${prof}.env" ]]; then
      _load_profile "$CONF/${prof}.env"; lbl="${LABEL:-}"
      st_c="$YLW"; st_t="saved"
      if _is_running "$prof"; then st_c="$GRN"; st_t="● running"; fi
    else
      lbl=""
    fi
    local lbl_disp="${lbl:--}"
    [[ ${#lbl_disp} -gt 20 ]] && lbl_disp="${lbl_disp:0:17}..."
    printf "  ${CYN}${B}%3s${R}   %-11s %-21s ${st_c}%s${R}\n" "$n" "$prof" "$lbl_disp" "$st_t"
  done
  _hr

  # ── IRAN Servers (slots 11-20) ──
  echo ""
  echo -e "  ${CYN}${B}┌───────────────────────────────────────────────┐${R}"
  echo -e "  ${CYN}${B}│   🇮🇷  IRAN SERVERS  (slots 11 – 20)           │${R}"
  echo -e "  ${CYN}${B}└───────────────────────────────────────────────┘${R}"
  echo -e "  ${DIM}  #   Name        Label                 Status${R}"
  _hr
  for i in $(seq 1 "$MAX"); do
    local prof="iran${i}"
    n=$((n + 1))
    local lbl st_c="$DIM" st_t="(empty)"
    if [[ -f "$CONF/${prof}.env" ]]; then
      _load_profile "$CONF/${prof}.env"; lbl="${LABEL:-}"
      st_c="$YLW"; st_t="saved"
      if _is_running "$prof"; then st_c="$GRN"; st_t="● running"; fi
    else
      lbl=""
    fi
    local lbl_disp="${lbl:--}"
    [[ ${#lbl_disp} -gt 20 ]] && lbl_disp="${lbl_disp:0:17}..."
    printf "  ${CYN}${B}%3s${R}   %-11s %-21s ${st_c}%s${R}\n" "$n" "$prof" "$lbl_disp" "$st_t"
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

# ── Bulk Operations ───────────────────────────────────────────
_bulk_start_all() {
  echo ""
  _msg_info "Starting all saved tunnels..."
  local profs=($(_list_saved_profiles))
  [[ ${#profs[@]} -eq 0 ]] && { _msg_warn "No saved profiles."; return; }
  for prof in "${profs[@]}"; do
    _run_slot "$prof"
  done
  _msg_ok "Bulk start completed."
}

_bulk_stop_all() {
  echo ""
  _msg_info "Stopping all saved tunnels..."
  local profs=($(_list_saved_profiles))
  [[ ${#profs[@]} -eq 0 ]] && { _msg_warn "No saved profiles."; return; }
  for prof in "${profs[@]}"; do
    _stop_slot "$prof"
  done
  _msg_ok "Bulk stop completed."
}

_bulk_restart_all() {
  echo ""
  _msg_info "Restarting all saved tunnels..."
  local profs=($(_list_saved_profiles))
  [[ ${#profs[@]} -eq 0 ]] && { _msg_warn "No saved profiles."; return; }
  for prof in "${profs[@]}"; do
    _restart_slot "$prof"
  done
  _msg_ok "Bulk restart completed."
}

# ── Manage single slot ────────────────────────────────────────
_manage_slot_menu() {
  local prof="$1"
  while true; do
    local f="$CONF/${prof}.env"
    local LABEL=""
    if [[ -f "$f" ]]; then
      _load_profile "$f"
    fi
    clear || true
    _dhr
    echo -e "  ${CYN}${B}  ⚙  MANAGE TUNNEL${R}  ${DIM}— $prof${LABEL:+ [$LABEL]}${R}"
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
    _menu_item "7" "🏷   Rename Label"
    _menu_item "8" "🗑   Delete Slot"
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
      7) _rename_label "$prof"; pause ;;
      8) _delete_slot "$prof"; pause; return ;;  # return after delete
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
    _section "BULK ACTIONS"
    _menu_item "S" "▶  Start All Tunnels"
    _menu_item "K" "⏹  Stop All Tunnels"
    _menu_item "R" "↺  Restart All Tunnels"
    echo ""
    _hr
    _menu_item "0" "◀  Back"
    _hr; echo ""
    local choice; read -r -p "  Select tunnel number, action (S/K/R), or 0: " choice < /dev/tty
    case "${choice,,}" in
      0) return ;;
      s) _bulk_start_all; pause ;;
      k) _bulk_stop_all; pause ;;
      r) _bulk_restart_all; pause ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
          local prof; prof="$(_saved_idx_to_prof "$choice")"
          if [[ -n "$prof" ]]; then
            _manage_slot_menu "$prof"
          else
            _msg_warn "Invalid selection."; sleep 0.8
          fi
        else
          _msg_warn "Invalid option."; sleep 0.8
        fi
        ;;
    esac
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
# Fetch server info ONCE here — banner reads from cache after this (instant)
_fetch_server_info
_main_menu

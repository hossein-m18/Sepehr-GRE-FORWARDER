#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# Sepehr GRE Tunnel Diagnostic Script
# Run on BOTH Iran and Kharej servers, compare the output
# ═══════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
SEPEHR_CONF_DIR="/etc/sepehr"
LOG="/tmp/sepehr-diag-$(date +%Y%m%d-%H%M%S).log"

log() { echo -e "$1" | tee -a "$LOG"; }
header() { log "\n${CYAN}═══════════════════════════════════════════════════════════${NC}"; log "${CYAN}  $1${NC}"; log "${CYAN}═══════════════════════════════════════════════════════════${NC}"; }
ok()   { log "  ${GREEN}✓${NC} $1"; }
fail() { log "  ${RED}✗${NC} $1"; }
warn() { log "  ${YELLOW}⚠${NC} $1"; }

header "SERVER INFO"
log "  Hostname : $(hostname)"
log "  Date UTC : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "  Date Iran: $(TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S')"
log "  Day (Tehran): $(TZ='Asia/Tehran' date +%d)"
log "  Hour (Tehran): $(TZ='Asia/Tehran' date +%H)"
log "  Uptime   : $(uptime -p 2>/dev/null || uptime)"

# ── Find all GRE tunnels ──
header "GRE TUNNELS"
mapfile -t GRE_IDS < <(find /etc/systemd/system -maxdepth 1 -type f -name 'gre*.service' 2>/dev/null | while IFS= read -r f; do
  f="$(basename "$f")"
  [[ "$f" =~ ^gre([0-9]+)\.service$ ]] && echo "${BASH_REMATCH[1]}"
done | sort -n)

if ((${#GRE_IDS[@]} == 0)); then
  fail "No GRE tunnels found!"
  exit 1
fi
ok "Found ${#GRE_IDS[@]} tunnel(s): ${GRE_IDS[*]}"

for ID in "${GRE_IDS[@]}"; do
  header "GRE${ID} - DETAILED DIAGNOSIS"

  CONF="${SEPEHR_CONF_DIR}/gre${ID}.conf"
  UNIT="/etc/systemd/system/gre${ID}.service"
  HAP_CFG="/etc/haproxy/conf.d/haproxy-gre${ID}.cfg"
  ROTATOR="/usr/local/bin/sepehr-recreate-gre${ID}.sh"

  # ── Config ──
  log "\n  ${YELLOW}[CONFIG]${NC}"
  if [[ -f "$CONF" ]]; then
    ok "Config exists: $CONF"
    source "$CONF"
    log "    SIDE       = ${SIDE:-?}"
    log "    LOCAL_IPS  = ${LOCAL_IPS:-?}"
    log "    REMOTE_IPS = ${REMOTE_IPS:-?}"
    log "    GRE_BASE   = ${GRE_BASE:-?}"
    log "    MTU        = ${MTU:-?}"
    log "    BLACKLIST  = ${BLACKLIST:-none}"
    log "    FAIL_COUNT = ${FAIL_COUNT:-?}"
    log "    LAST_SUCCESS = $(date -d @${LAST_SUCCESS:-0} '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${LAST_SUCCESS:-?}")"
  else
    fail "Config NOT found: $CONF"
  fi

  # ── Unit file ──
  log "\n  ${YELLOW}[UNIT FILE]${NC}"
  if [[ -f "$UNIT" ]]; then
    ok "Unit exists: $UNIT"
    unit_local=$(grep -oP 'ip tunnel add gre[0-9]+ mode gre local \K[0-9.]+' "$UNIT" 2>/dev/null | head -n1 || echo "?")
    unit_remote=$(grep -oP 'remote \K[0-9.]+' "$UNIT" 2>/dev/null | head -n1 || echo "?")
    unit_gre_ip=$(grep -oP 'ip addr add \K[0-9.]+' "$UNIT" 2>/dev/null | head -n1 || echo "?")
    unit_mtu=$(grep -oP 'ip link set gre[0-9]+ mtu \K[0-9]+' "$UNIT" 2>/dev/null | head -n1 || echo "default")
    log "    tunnel local  = $unit_local"
    log "    tunnel remote = $unit_remote"
    log "    GRE internal  = $unit_gre_ip"
    log "    MTU           = $unit_mtu"
  else
    fail "Unit NOT found: $UNIT"
  fi

  # ── Expected calculation (what rotation SHOULD produce) ──
  log "\n  ${YELLOW}[EXPECTED IPs - Time-Based Calculation]${NC}"
  if [[ -f "$CONF" ]]; then
    source "$CONF"
    IFS=',' read -ra local_arr <<< "${LOCAL_IPS:-}"
    IFS=',' read -ra remote_arr <<< "${REMOTE_IPS:-}"
    local_count=${#local_arr[@]}
    remote_count=${#remote_arr[@]}

    side_mode="${SIDE:-IRAN}"
    if [[ "$side_mode" == "IRAN" ]]; then
      iran_count=$local_count
      kharej_count=$remote_count
    else
      iran_count=$remote_count
      kharej_count=$local_count
    fi
    total_paths=$((iran_count * kharej_count))

    day=$(TZ="Asia/Tehran" date +%d)
    hour=$(TZ="Asia/Tehran" date +%H)
    base_index=$(( (10#$day + 10#$hour) % total_paths ))

    # Skip blacklisted
    IFS=',' read -ra bl_arr <<< "${BLACKLIST:-}"
    path_index=$base_index
    for ((i=0; i<total_paths; i++)); do
      is_bl=0
      for b in "${bl_arr[@]}"; do
        [[ "$(echo "$b" | tr -d ' ')" == "$path_index" ]] && is_bl=1
      done
      ((is_bl == 0)) && break
      path_index=$(( (path_index + 1) % total_paths ))
    done

    iran_idx=$((path_index / kharej_count))
    kharej_idx=$((path_index % kharej_count))

    if [[ "$side_mode" == "KHAREJ" ]]; then
      exp_local="${local_arr[$kharej_idx]}"
      exp_remote="${remote_arr[$iran_idx]}"
    else
      exp_local="${local_arr[$iran_idx]}"
      exp_remote="${remote_arr[$kharej_idx]}"
    fi

    log "    day=$day hour=$hour base_index=$base_index path_index=$path_index"
    log "    iran_count=$iran_count kharej_count=$kharej_count total_paths=$total_paths"
    log "    Expected LOCAL  = ${GREEN}$exp_local${NC}"
    log "    Expected REMOTE = ${GREEN}$exp_remote${NC}"

    # Check match with unit
    if [[ "${unit_local:-}" == "$exp_local" ]]; then
      ok "Unit LOCAL matches expected"
    else
      fail "Unit LOCAL MISMATCH: unit=$unit_local vs expected=$exp_local"
    fi
    if [[ "${unit_remote:-}" == "$exp_remote" ]]; then
      ok "Unit REMOTE matches expected"
    else
      fail "Unit REMOTE MISMATCH: unit=$unit_remote vs expected=$exp_remote"
    fi

    # GRE internal IP check
    if [[ -n "${GRE_BASE:-}" ]]; then
      IFS='.' read -r base1 base2 base3 base4 <<< "$GRE_BASE"
      DAY_DEC=$((10#$day))
      HOUR_DEC=$((10#$hour))
      exp_third=$(( (base3 + DAY_DEC + HOUR_DEC) % 254 + 1 ))
      if [[ "$side_mode" == "IRAN" ]]; then exp_fourth=1; else exp_fourth=2; fi
      exp_gre_ip="${base1}.${base2}.${exp_third}.${exp_fourth}"
      exp_peer_ip="${base1}.${base2}.${exp_third}.$((3 - exp_fourth))"

      log "    Expected GRE IP   = ${GREEN}$exp_gre_ip${NC}"
      log "    Expected Peer IP  = ${GREEN}$exp_peer_ip${NC}"

      if [[ "${unit_gre_ip:-}" == "$exp_gre_ip" ]]; then
        ok "GRE internal IP matches expected"
      else
        fail "GRE internal IP MISMATCH: unit=$unit_gre_ip vs expected=$exp_gre_ip"
      fi
    fi
  fi

  # ── Live interface ──
  log "\n  ${YELLOW}[LIVE INTERFACE]${NC}"
  if ip link show "gre${ID}" >/dev/null 2>&1; then
    live_state=$(ip link show "gre${ID}" 2>/dev/null | head -1)
    if echo "$live_state" | grep -q "UP"; then
      ok "gre${ID} is UP"
    else
      fail "gre${ID} is DOWN"
    fi
    log "    $live_state"
    live_ip=$(ip -4 -o addr show dev "gre${ID}" 2>/dev/null | awk '{print $4}' | head -n1 || echo "none")
    log "    Live IP: $live_ip"
    live_peer=$(ip -d link show "gre${ID}" 2>/dev/null | grep -oP 'remote \K[0-9.]+' | head -n1 || echo "?")
    live_local=$(ip -d link show "gre${ID}" 2>/dev/null | grep -oP 'local \K[0-9.]+' | head -n1 || echo "?")
    log "    Live tunnel local : $live_local"
    log "    Live tunnel remote: $live_peer"
  else
    fail "gre${ID} interface does NOT exist"
  fi

  # ── Service status ──
  log "\n  ${YELLOW}[SERVICE STATUS]${NC}"
  if systemctl is-active --quiet "gre${ID}.service" 2>/dev/null; then
    ok "gre${ID}.service is ACTIVE"
  else
    fail "gre${ID}.service is NOT active"
    systemctl status "gre${ID}.service" --no-pager 2>&1 | tail -5 | while IFS= read -r l; do log "    $l"; done
  fi

  # ── Ping tests ──
  log "\n  ${YELLOW}[CONNECTIVITY TESTS]${NC}"

  # Ping remote tunnel endpoint
  if [[ -n "${unit_remote:-}" && "$unit_remote" != "?" ]]; then
    if ping -c 2 -W 2 "$unit_remote" >/dev/null 2>&1; then
      ok "Ping remote endpoint ($unit_remote): OK"
    else
      fail "Ping remote endpoint ($unit_remote): FAILED"
    fi
  fi

  # Ping GRE peer (internal)
  if [[ -n "${exp_peer_ip:-}" ]]; then
    if ping -c 2 -W 2 "$exp_peer_ip" >/dev/null 2>&1; then
      ok "Ping GRE peer ($exp_peer_ip): OK"
    else
      fail "Ping GRE peer ($exp_peer_ip): FAILED"
    fi
  fi

  # ── HAProxy config ──
  log "\n  ${YELLOW}[HAPROXY]${NC}"
  if [[ -f "$HAP_CFG" ]]; then
    ok "HAProxy config: $HAP_CFG"
    hap_peer=$(grep -oP 'server\s+\S+\s+\K[0-9.]+' "$HAP_CFG" 2>/dev/null | head -n1 || echo "?")
    log "    Backend peer IP: $hap_peer"
    if [[ -n "${exp_peer_ip:-}" && "$hap_peer" == "$exp_peer_ip" ]]; then
      ok "HAProxy peer matches expected GRE peer"
    elif [[ -n "${exp_peer_ip:-}" ]]; then
      fail "HAProxy peer MISMATCH: haproxy=$hap_peer vs expected=$exp_peer_ip"
    fi
  else
    log "    No HAProxy config (normal for KHAREJ side)"
  fi

  # ── Rotation script ──
  log "\n  ${YELLOW}[ROTATION SCRIPT]${NC}"
  if [[ -x "$ROTATOR" ]]; then
    ok "Rotator exists: $ROTATOR"
    if grep -q 'sed -i\.bak' "$ROTATOR" 2>/dev/null; then
      fail "Rotator uses sed -i.bak (OLD version - will create .bak files!)"
    else
      ok "Rotator uses sed -i (new version)"
    fi
  else
    fail "Rotator NOT found or not executable: $ROTATOR"
  fi

  # ── Cron ──
  log "\n  ${YELLOW}[CRON]${NC}"
  if crontab -l 2>/dev/null | grep -qF "sepehr-recreate-gre${ID}"; then
    ok "Cron entry exists"
    crontab -l 2>/dev/null | grep "sepehr-recreate-gre${ID}" | while IFS= read -r l; do log "    $l"; done
  else
    fail "No cron entry for GRE${ID}"
  fi

  # ── .bak files ──
  log "\n  ${YELLOW}[STALE .BAK FILES]${NC}"
  local bak_found=0
  for bak in /etc/haproxy/conf.d/*gre${ID}*.bak /etc/systemd/system/gre${ID}.service.bak; do
    if [[ -f "$bak" ]]; then
      fail "Stale .bak found: $bak"
      bak_found=1
    fi
  done
  ((bak_found == 0)) && ok "No stale .bak files"

  # ── Port conflicts ──
  log "\n  ${YELLOW}[PORT CONFLICTS]${NC}"
  if [[ -f "$HAP_CFG" ]]; then
    local conflict=0
    while IFS= read -r port; do
      [[ -z "$port" ]] && continue
      blocker=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -v haproxy || true)
      if [[ -n "$blocker" ]]; then
        fail "Port $port blocked by: $blocker"
        conflict=1
      fi
    done < <(grep -oP 'bind\s+\S+:\K[0-9]+' "$HAP_CFG" 2>/dev/null)
    ((conflict == 0)) && ok "No port conflicts"
  fi

done

# ── HAProxy overall ──
header "HAPROXY STATUS"
if systemctl is-active --quiet haproxy 2>/dev/null; then
  ok "haproxy.service is ACTIVE"
else
  fail "haproxy.service is NOT active"
  journalctl -u haproxy --no-pager -n 5 2>&1 | while IFS= read -r l; do log "    $l"; done
fi

# ── Stale socat ──
header "STALE PROCESSES"
socat_pids=$(pgrep -x socat 2>/dev/null || true)
if [[ -n "$socat_pids" ]]; then
  fail "Stale socat process(es) found:"
  ps -p $(echo "$socat_pids" | tr '\n' ',') -o pid,args 2>/dev/null | while IFS= read -r l; do log "    $l"; done
else
  ok "No stale socat processes"
fi

header "DIAGNOSIS COMPLETE"
log "\n  Full log saved to: ${GREEN}$LOG${NC}"
log "  Run this on BOTH Iran and Kharej servers and compare outputs!"
log "  Key things to compare:"
log "    - Expected LOCAL/REMOTE IPs must be SYMMETRIC"
log "    - GRE internal IPs: Iran=.1, Kharej=.2 (same third octet)"
log "    - Times must match (same day/hour in Tehran timezone)\n"

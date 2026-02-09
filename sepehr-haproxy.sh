#!/usr/bin/env bash

set +e
set +u
export LC_ALL=C
LOG_LINES=()
LOG_MIN=3
LOG_MAX=10

banner() {
  cat <<'EOF'
╔═════════════════════════════════════════════════════╗
║                                                     ║
║   ███████╗███████╗██████╗ ███████╗██╗  ██╗██████╗   ║
║   ██╔════╝██╔════╝██╔══██╗██╔════╝██║  ██║██╔══██╗  ║
║   ███████╗█████╗  ██████╔╝█████╗  ███████║██████╔╝  ║
║   ╚════██║██╔══╝  ██╔═══╝ ██╔══╝  ██╔══██║██╔══██╗  ║
║   ███████║███████╗██║     ███████╗██║  ██║██║  ██║  ║
║   ╚══════╝╚══════╝╚═╝     ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝  ║
║                                                     ║
║              k O J A I    B A B A ?                 ║
║                                                     ║
╚═════════════════════════════════════════════════════╝
EOF
}

add_log() {
    local msg="$1"
    local ts
    ts="$(date +"%H:%M:%S")"
    LOG_LINES+=("[$ts] $msg")
    if ((${#LOG_LINES[@]} > LOG_MAX)); then
        LOG_LINES=("${LOG_LINES[@]: -$LOG_MAX}")
    fi
}

render() {
    clear
    banner
    echo
    local shown_count="${#LOG_LINES[@]}"
    local height=$shown_count
    ((height < LOG_MIN)) && height=$LOG_MIN
    ((height > LOG_MAX)) && height=$LOG_MAX
    
    echo "┌───────────────────────────── ACTION LOG ─────────────────────────────┐"
    local start_index=0
    if ((${#LOG_LINES[@]} > height)); then
        start_index=$((${#LOG_LINES[@]} - height))
    fi
    
    local i line
    for ((i=start_index; i<${#LOG_LINES[@]}; i++)); do
        line="${LOG_LINES[$i]}"
        printf "│ %-68s │\n" "$line"
    done
    
    local missing=$((height - (${#LOG_LINES[@]} - start_index)))
    for ((i=0; i<missing; i++)); do
        printf "│ %-68s │\n" ""
    done
    
    echo "└──────────────────────────────────────────────────────────────────────┘"
    echo
}

pause_enter() {
    echo
    read -r -p "Press ENTER to return to menu..." _
}

die_soft() {
    add_log "ERROR: $1"
    render
    pause_enter
}

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root. Re-running with sudo..."
        exec sudo -E bash "$0" "$@"
    fi
}

trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

valid_octet() {
  local o="$1"
  [[ "$o" =~ ^[0-9]+$ ]] && ((o>=0 && o<=255))
}

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  valid_octet "$a" && valid_octet "$b" && valid_octet "$c" && valid_octet "$d"
}

valid_port() {
  local p="$1"
  is_int "$p" || return 1
  ((p>=1 && p<=65535))
}

valid_gre_base() {
  local ip="$1"
  valid_ipv4 "$ip" || return 1
  [[ "$ip" =~ \.0$ ]] || return 1
  return 0
}

random_gre_base() {
  # Generate random private IP range for GRE tunnel
  # Uses 10.x.x.0 or 172.16-31.x.0 or 192.168.x.0
  local type=$((RANDOM % 3))
  case $type in
    0) echo "10.$((RANDOM % 256)).$((RANDOM % 256)).0" ;;
    1) echo "172.$((16 + RANDOM % 16)).$((RANDOM % 256)).0" ;;
    2) echo "192.168.$((RANDOM % 256)).0" ;;
  esac
}

ipv4_set_last_octet() {
  local ip="$1" last="$2"
  IFS='.' read -r a b c d <<<"$ip"
  echo "${a}.${b}.${c}.${last}"
}

get_server_ips() {
  local -a ips=()
  local ip
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    # Skip private IP ranges (10.x.x.x, 172.16-31.x.x, 192.168.x.x, 127.x.x.x)
    [[ "$ip" =~ ^10\. ]] && continue
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && continue
    [[ "$ip" =~ ^192\.168\. ]] && continue
    [[ "$ip" =~ ^127\. ]] && continue
    ips+=("$ip")
  done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | sort -u)
  printf '%s\n' "${ips[@]}"
}

select_local_ip() {
  local prompt="$1" __var="$2"
  local -a SERVER_IPS=()
  mapfile -t SERVER_IPS < <(get_server_ips)

  if ((${#SERVER_IPS[@]} == 0)); then
    add_log "ERROR: No public IPs detected on this server."
    return 1
  fi

  local choice
  while true; do
    render
    echo "$prompt"
    echo
    local i
    for ((i=0; i<${#SERVER_IPS[@]}; i++)); do
      printf "%d) %s\n" $((i+1)) "${SERVER_IPS[$i]}"
    done
    echo "0) Enter manually"
    echo
    read -r -e -p "Select: " choice
    choice="$(trim "$choice")"

    if [[ "$choice" == "0" ]]; then
      local manual_ip
      ask_until_valid "Enter IP manually:" valid_ipv4 manual_ip
      printf -v "$__var" '%s' "$manual_ip"
      add_log "Selected (manual): $manual_ip"
      return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#SERVER_IPS[@]})); then
      local selected_ip="${SERVER_IPS[$((choice-1))]}"
      printf -v "$__var" '%s' "$selected_ip"
      add_log "Selected: $selected_ip"
      return 0
    fi

    add_log "Invalid selection: $choice"
  done
}

ask_until_valid() {
  local prompt="$1" validator="$2" __var="$3"
  local ans=""
  while true; do
    render
    read -r -e -p "$prompt " ans
    ans="$(trim "$ans")"
    if [[ -z "$ans" ]]; then
      add_log "Empty input. Please try again."
      continue
    fi
    if "$validator" "$ans"; then
      printf -v "$__var" '%s' "$ans"
      add_log "OK: $prompt $ans"
      return 0
    else
      add_log "Invalid: $prompt $ans"
      add_log "Please enter a valid value."
    fi
  done
}

ask_ports() {
  local prompt="ForWard PORT (80 | 80,2053 | 2050-2060):"
  local raw=""
  while true; do
    render
    read -r -e -p "$prompt " raw
    raw="$(trim "$raw")"
    raw="${raw// /}"

    if [[ -z "$raw" ]]; then
      add_log "Empty ports. Please try again."
      continue
    fi

    local -a ports=()
    local ok=1

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      valid_port "$raw" && ports+=("$raw") || ok=0

    elif [[ "$raw" =~ ^[0-9]+-[0-9]+$ ]]; then
      local s="${raw%-*}"
      local e="${raw#*-}"
      if valid_port "$s" && valid_port "$e" && ((s<=e)); then
        local p
        for ((p=s; p<=e; p++)); do ports+=("$p"); done
      else
        ok=0
      fi

    elif [[ "$raw" =~ ^[0-9]+(,[0-9]+)+$ ]]; then
      IFS=',' read -r -a parts <<<"$raw"
      local part
      for part in "${parts[@]}"; do
        valid_port "$part" && ports+=("$part") || { ok=0; break; }
      done
    else
      ok=0
    fi

    if ((ok==0)); then
      add_log "Invalid ports: $raw"
      add_log "Examples: 80 | 80,2053 | 2050-2060"
      continue
    fi

    mapfile -t PORT_LIST < <(printf "%s\n" "${ports[@]}" | awk '!seen[$0]++' | sort -n)
    add_log "Ports accepted: ${PORT_LIST[*]}"
    return 0
  done
}

SEPEHR_CONF_DIR="/etc/sepehr"

ensure_sepehr_conf_dir() {
  mkdir -p "$SEPEHR_CONF_DIR" >/dev/null 2>&1 || true
}

sepehr_conf_path() {
  local id="$1"
  echo "${SEPEHR_CONF_DIR}/gre${id}.conf"
}

ask_multiple_local_ips() {
  local prompt="$1" __var="$2"
  local -a SERVER_IPS=()
  local -a SELECTED_IPS=()
  mapfile -t SERVER_IPS < <(get_server_ips)

  if ((${#SERVER_IPS[@]} == 0)); then
    add_log "ERROR: No public IPs detected on this server."
    return 1
  fi

  while true; do
    render
    echo "$prompt"
    echo "(Select multiple IPs, enter 'd' when done)"
    echo
    local i
    for ((i=0; i<${#SERVER_IPS[@]}; i++)); do
      local marker=" "
      for sel in "${SELECTED_IPS[@]}"; do
        [[ "$sel" == "${SERVER_IPS[$i]}" ]] && marker="*"
      done
      printf "%d) [%s] %s\n" $((i+1)) "$marker" "${SERVER_IPS[$i]}"
    done
    echo
    echo "Selected: ${SELECTED_IPS[*]:-none}"
    echo
    echo "a) Select ALL IPs"
    echo "0) Enter IP manually"
    echo "d) Done selecting"
    echo

    local choice
    read -r -e -p "Select: " choice
    choice="$(trim "$choice")"

    if [[ "${choice,,}" == "a" || "${choice,,}" == "all" ]]; then
      # Select all server IPs
      SELECTED_IPS=("${SERVER_IPS[@]}")
      add_log "Selected ALL IPs: ${SELECTED_IPS[*]}"
      continue
    fi

    if [[ "${choice,,}" == "d" || "${choice,,}" == "done" ]]; then
      if ((${#SELECTED_IPS[@]} == 0)); then
        add_log "ERROR: Select at least one IP."
        continue
      fi
      break
    fi

    if [[ "$choice" == "0" ]]; then
      local manual_ip
      ask_until_valid "Enter IP manually:" valid_ipv4 manual_ip
      local exists=0
      for sel in "${SELECTED_IPS[@]}"; do
        [[ "$sel" == "$manual_ip" ]] && exists=1
      done
      if ((exists == 0)); then
        SELECTED_IPS+=("$manual_ip")
        add_log "Added (manual): $manual_ip"
      else
        add_log "Already selected: $manual_ip"
      fi
      continue
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#SERVER_IPS[@]})); then
      local ip="${SERVER_IPS[$((choice-1))]}"
      local exists=0 idx=-1 j
      for ((j=0; j<${#SELECTED_IPS[@]}; j++)); do
        if [[ "${SELECTED_IPS[$j]}" == "$ip" ]]; then
          exists=1
          idx=$j
        fi
      done
      if ((exists == 1)); then
        unset 'SELECTED_IPS[idx]'
        SELECTED_IPS=("${SELECTED_IPS[@]}")
        add_log "Removed: $ip"
      else
        SELECTED_IPS+=("$ip")
        add_log "Added: $ip"
      fi
      continue
    fi

    add_log "Invalid selection: $choice"
  done

  local result
  result=$(printf '%s,' "${SELECTED_IPS[@]}")
  result="${result%,}"
  printf -v "$__var" '%s' "$result"
  add_log "Local IPs: $result"
  return 0
}

ask_remote_ips() {
  local prompt="$1" __var="$2"
  local -a REMOTE_IPS=()

  while true; do
    render
    echo "$prompt"
    echo "(Enter IPs one by one, 'd' when done)"
    echo
    echo "Current list: ${REMOTE_IPS[*]:-none}"
    echo

    local input
    read -r -e -p "Enter IP (or 'd'): " input
    input="$(trim "$input")"

    if [[ "${input,,}" == "d" || "${input,,}" == "done" ]]; then
      if ((${#REMOTE_IPS[@]} == 0)); then
        add_log "ERROR: Enter at least one remote IP."
        continue
      fi
      break
    fi

    if valid_ipv4 "$input"; then
      local exists=0
      for r in "${REMOTE_IPS[@]}"; do
        [[ "$r" == "$input" ]] && exists=1
      done
      if ((exists == 0)); then
        REMOTE_IPS+=("$input")
        add_log "Added remote: $input"
      else
        add_log "Already exists: $input"
      fi
    else
      add_log "Invalid IP: $input"
    fi
  done

  local result
  result=$(printf '%s,' "${REMOTE_IPS[@]}")
  result="${result%,}"
  printf -v "$__var" '%s' "$result"
  add_log "Remote IPs: $result"
  return 0
}

write_sepehr_conf() {
  local id="$1" side="$2" local_ips="$3" remote_ips="$4" gre_base="$5" mtu="$6"
  local conf
  conf="$(sepehr_conf_path "$id")"

  ensure_sepehr_conf_dir

  # Calculate total paths (local_count × remote_count)
  local local_count remote_count total_paths
  IFS=',' read -ra tmp_local <<< "$local_ips"
  IFS=',' read -ra tmp_remote <<< "$remote_ips"
  local_count=${#tmp_local[@]}
  remote_count=${#tmp_remote[@]}
  total_paths=$((local_count * remote_count))

  cat >"$conf" <<EOF
# Sepehr GRE${id} Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
SIDE="${side}"
LOCAL_IPS="${local_ips}"
REMOTE_IPS="${remote_ips}"
GRE_BASE="${gre_base}"
MTU="${mtu}"
TOTAL_PATHS=${total_paths}
BLACKLIST=""
FAIL_COUNT=0
LAST_SUCCESS=$(date +%s)
EOF

  add_log "Config written: $conf (${total_paths} paths)"
  return 0
}

read_sepehr_conf() {
  local id="$1"
  local conf
  conf="$(sepehr_conf_path "$id")"
  [[ -f "$conf" ]] || return 1
  source "$conf"
  return 0
}

calculate_current_ips() {
  local id="$1"
  local conf
  conf="$(sepehr_conf_path "$id")"
  [[ -f "$conf" ]] || return 1

  source "$conf"

  IFS=',' read -r -a local_arr <<< "$LOCAL_IPS"
  IFS=',' read -r -a remote_arr <<< "$REMOTE_IPS"

  local count_local=${#local_arr[@]}
  local count_remote=${#remote_arr[@]}

  local day hour offset
  day=$(TZ="Asia/Tehran" date +%d)
  hour=$(TZ="Asia/Tehran" date +%H)
  offset=${OFFSET:-0}

  local index_local=$(( (10#$day + 10#$hour + offset) % count_local ))
  local index_remote=$(( (10#$day + 10#$hour + offset) % count_remote ))

  CALC_LOCAL_IP="${local_arr[$index_local]}"
  CALC_REMOTE_IP="${remote_arr[$index_remote]}"

  return 0
}

apply_calculated_ips() {
  local id="$1"
  calculate_current_ips "$id" || return 1

  local unit="/etc/systemd/system/gre${id}.service"
  [[ -f "$unit" ]] || return 1

  sed -i -E "s/(ip tunnel add gre${id} mode gre local )[0-9.]+/\1${CALC_LOCAL_IP}/" "$unit"
  sed -i -E "s/(remote )[0-9.]+ (ttl)/\1${CALC_REMOTE_IP} \2/" "$unit"

  local conf
  conf="$(sepehr_conf_path "$id")"
  source "$conf"
  if [[ "$SIDE" == "IRAN" ]]; then
    local hap_cfg="/etc/haproxy/conf.d/haproxy-gre${id}.cfg"
    if [[ -f "$hap_cfg" ]]; then
      local peer_gre_ip
      peer_gre_ip="$(ipv4_set_last_octet "$GRE_BASE" 2)"
      sed -i -E "s/(server[[:space:]]+gre${id}_b_[0-9]+[[:space:]]+)[0-9.]+(:)/\1${peer_gre_ip}\2/g" "$hap_cfg"
    fi
  fi

  return 0
}

increment_offset() {
  local id="$1"
  local conf
  conf="$(sepehr_conf_path "$id")"
  [[ -f "$conf" ]] || return 1

  source "$conf"
  local new_offset=$((OFFSET + 1))
  sed -i "s/^OFFSET=.*/OFFSET=${new_offset}/" "$conf"
  add_log "GRE${id}: OFFSET incremented to ${new_offset}"
  return 0
}

reset_fail_count() {
  local id="$1"
  local conf
  conf="$(sepehr_conf_path "$id")"
  [[ -f "$conf" ]] || return 1
  sed -i "s/^FAIL_COUNT=.*/FAIL_COUNT=0/" "$conf"
  sed -i "s/^LAST_SUCCESS=.*/LAST_SUCCESS=$(date +%s)/" "$conf"
}

create_auto_cron() {
  local id="$1" side="$2"
  local script="/usr/local/bin/sepehr-recreate-gre${id}.sh"
  local cron_line="*/30 * * * * ${script}"

  # Always recreate script to ensure it has latest logic
  cat > "$script" <<'ROTATION_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

ID="__ID__"
SIDE="__SIDE__"
CONF="/etc/sepehr/gre${ID}.conf"
UNIT="/etc/systemd/system/gre${ID}.service"
HAP_CFG="/etc/haproxy/conf.d/haproxy-gre${ID}.cfg"
LOG_FILE="/var/log/sepehr-gre${ID}.log"
TZ="Asia/Tehran"

mkdir -p /var/log >/dev/null 2>&1 || true
touch "$LOG_FILE" >/dev/null 2>&1 || true

log() { echo "[$(TZ="$TZ" date '+%Y-%m-%d %H:%M %Z')] $1" >> "$LOG_FILE"; }

[[ -f "$UNIT" ]] || { log "ERROR: Unit not found: $UNIT"; exit 1; }

# ============================================
# PART 1: PATH-BASED PUBLIC IP SELECTION
# Both sides select same path using DAY+HOUR
# Blacklisted paths are skipped
# ============================================
if [[ -f "$CONF" ]]; then
  source "$CONF"

  IFS=',' read -r -a local_arr <<< "$LOCAL_IPS"
  IFS=',' read -r -a remote_arr <<< "$REMOTE_IPS"

  local_count=${#local_arr[@]}
  remote_count=${#remote_arr[@]}
  total_paths=$((local_count * remote_count))

  # Parse blacklist into array
  declare -a blacklist=()
  if [[ -n "${BLACKLIST:-}" ]]; then
    IFS=',' read -r -a blacklist <<< "$BLACKLIST"
  fi

  # Function to check if path is blacklisted
  is_blacklisted() {
    local p=$1
    for b in "${blacklist[@]}"; do
      [[ "$b" == "$p" ]] && return 0
    done
    return 1
  }

  # Count active paths
  active_count=0
  for ((p=0; p<total_paths; p++)); do
    is_blacklisted "$p" || ((active_count++))
  done

  # If all paths blacklisted, reset blacklist
  if ((active_count == 0)); then
    log "All paths blacklisted - resetting"
    sed -i 's/^BLACKLIST=.*/BLACKLIST=""/' "$CONF"
    blacklist=()
    active_count=$total_paths
  fi

  # Calculate base index from time (synchronized across servers)
  day=$(TZ="Asia/Tehran" date +%d)
  hour=$(TZ="Asia/Tehran" date +%H)
  base_index=$(( (10#$day + 10#$hour) % total_paths ))

  # Find next active path starting from base_index
  path_index=$base_index
  for ((i=0; i<total_paths; i++)); do
    if ! is_blacklisted "$path_index"; then
      break
    fi
    path_index=$(( (path_index + 1) % total_paths ))
  done

  # Calculate local and remote indices from path_index
  # path = local_idx * remote_count + remote_idx
  local_idx=$((path_index / remote_count))
  remote_idx=$((path_index % remote_count))

  NEW_LOCAL="${local_arr[$local_idx]}"
  NEW_REMOTE="${remote_arr[$remote_idx]}"

  log "PATH $path_index: Local=$NEW_LOCAL Remote=$NEW_REMOTE (active=$active_count/${total_paths})"

  sed -i -E "s/(ip tunnel add gre$ID mode gre local )[0-9.]+/\1$NEW_LOCAL/" "$UNIT"
  sed -i -E "s/(remote )[0-9.]+ (ttl)/\1$NEW_REMOTE \2/" "$UNIT"

  sed -i "s/^FAIL_COUNT=.*/FAIL_COUNT=0/" "$CONF"
  sed -i "s/^LAST_SUCCESS=.*/LAST_SUCCESS=$(date +%s)/" "$CONF"
fi

# ============================================
# PART 2: Change GRE INTERNAL IP (old algorithm)
# ============================================
old_gre_ip=$(grep -oP 'ip addr add \K([0-9.]+)' "$UNIT" | head -n1 || true)

if [[ -n "$old_gre_ip" ]]; then
  DAY=$(TZ="$TZ" date +%d)
  HOUR=$(TZ="$TZ" date +%H)
  AMPM=$(TZ="$TZ" date +%p)

  DAY_DEC=$((10#$DAY))
  HOUR_DEC=$((10#$HOUR))
  datetimecountnumber=$((DAY_DEC + HOUR_DEC))

  IFS='.' read -r b1 oldblocknumb b3 b4 <<< "$old_gre_ip"

  if (( oldblocknumb > 230 )); then
    oldblock_calc=4
  else
    oldblock_calc=$oldblocknumb
  fi

  if (( DAY_DEC <= 15 )); then
    if [[ "$AMPM" == "AM" ]]; then
      newblock=$((datetimecountnumber + oldblock_calc + 7))
    else
      newblock=$((datetimecountnumber + oldblock_calc - 13))
    fi
  else
    if [[ "$AMPM" == "AM" ]]; then
      newblock=$((datetimecountnumber + oldblock_calc + 3))
    else
      newblock=$((datetimecountnumber + oldblock_calc - 5))
    fi
  fi

  (( newblock > 245 )) && newblock=245
  (( newblock < 0 )) && newblock=0

  new_gre_ip="${b1}.${newblock}.${datetimecountnumber}.${b4}"

  log "GRE INTERNAL IP rotation: $old_gre_ip -> $new_gre_ip"

  sed -i.bak -E "s/ip addr add [0-9.]+\/30/ip addr add ${new_gre_ip}\/30/" "$UNIT"

  # Update HAProxy if IRAN side - use PEER IP (change last octet)
  if [[ "$SIDE" == "IRAN" && -f "$HAP_CFG" ]]; then
    peer_gre_ip="${new_gre_ip%.*}.2"
    sed -i.bak -E "s/(server[[:space:]]+gre${ID}_b_[0-9]+[[:space:]]+)[0-9.]+(:[0-9]+[[:space:]]+check)/\1${peer_gre_ip}\2/g" "$HAP_CFG"
    log "HAProxy config updated with peer GRE IP: $peer_gre_ip"
  fi
fi

# ============================================
# PART 3: Restart services
# ============================================
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl restart "gre${ID}.service" >/dev/null 2>&1 || true

if [[ "$SIDE" == "IRAN" ]]; then
  if command -v haproxy >/dev/null 2>&1; then
    haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/ >/dev/null 2>&1 || {
      log "ERROR: HAProxy config validation failed"; exit 1;
    }
  fi
  systemctl restart haproxy >/dev/null 2>&1 || true
  log "HAProxy restarted"
fi

log "Rotation complete | GRE${ID} | SIDE=$SIDE"
ROTATION_SCRIPT

  # Replace placeholders
  sed -i "s|__ID__|${id}|g" "$script"
  sed -i "s|__SIDE__|${side}|g" "$script"
  chmod +x "$script"

  # Add cron if not exists
  if ! crontab -l 2>/dev/null | grep -qF "$script"; then
    (crontab -l 2>/dev/null || true; echo "$cron_line") | crontab -
    add_log "Auto-cron enabled: every 30 minutes"
  else
    add_log "Auto-cron already exists for GRE${id}"
  fi

  return 0
}

ensure_iproute_only() {
  add_log "Checking required package: iproute2"
  render

  if command -v ip >/dev/null 2>&1; then
    add_log "iproute2 is already installed."
    return 0
  fi

  add_log "Installing missing package: iproute2"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y iproute2 >/dev/null 2>&1 && add_log "iproute2 installed successfully." || return 1
  return 0
}

ensure_packages() {
  add_log "Checking required packages: iproute2, haproxy"
  render
  local missing=()
  command -v ip >/dev/null 2>&1 || missing+=("iproute2")
  command -v haproxy >/dev/null 2>&1 || missing+=("haproxy")

  if ((${#missing[@]}==0)); then
    add_log "All required packages are installed."
    return 0
  fi

  add_log "Installing missing packages: ${missing[*]}"
  render
  apt-get update -y >/dev/null 2>&1
  apt-get install -y "${missing[@]}" >/dev/null 2>&1 && add_log "Packages installed successfully." || return 1
  return 0
}

systemd_reload() { systemctl daemon-reload >/dev/null 2>&1; }
unit_exists() { [[ -f "/etc/systemd/system/$1" ]]; }
enable_now() { systemctl enable --now "$1" >/dev/null 2>&1; }

show_unit_status_brief() {
  systemctl --no-pager --full status "$1" 2>&1 | sed -n '1,12p'
}

valid_mtu() {
  local m="$1"
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  ((m>=576 && m<=1600))
}

ensure_mtu_line_in_unit() {
  local id="$1" mtu="$2" file="$3"

  [[ -f "$file" ]] || return 0

  if grep -qE "^ExecStart=/sbin/ip link set gre${id} mtu[[:space:]]+[0-9]+$" "$file"; then
    sed -i.bak -E "s|^ExecStart=/sbin/ip link set gre${id} mtu[[:space:]]+[0-9]+$|ExecStart=/sbin/ip link set gre${id} mtu ${mtu}|" "$file"
    add_log "Updated MTU line in: $file"
    return 0
  fi

  if grep -qE "^ExecStart=/sbin/ip link set gre${id} up$" "$file"; then
    sed -i.bak -E "s|^ExecStart=/sbin/ip link set gre${id} up$|ExecStart=/sbin/ip link set gre${id} mtu ${mtu}\nExecStart=/sbin/ip link set gre${id} up|" "$file"
    add_log "Inserted MTU line in: $file"
    return 0
  fi
  printf "\nExecStart=/sbin/ip link set gre%s mtu %s\n" "$id" "$mtu" >> "$file"
  add_log "WARNING: 'ip link set gre${id} up' not found; appended MTU line at end: $file"
}


make_gre_service() {
  local id="$1" local_ip="$2" remote_ip="$3" local_gre_ip="$4" key="$5" mtu_val="$6"
  local unit="gre${id}.service"
  local path="/etc/systemd/system/${unit}"
  local mtu_line=""

  if [[ -n "$mtu_val" ]]; then
    mtu_line="ExecStart=/sbin/ip link set gre${id} mtu ${mtu_val}"
  fi

  if unit_exists "$unit"; then
    add_log "Service already exists: $unit"
    return 2
  fi

  add_log "Creating: $path"
  render

  cat >"$path" <<EOF
[Unit]
Description=GRE Tunnel to (${remote_ip})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c "/sbin/ip tunnel del gre${id} 2>/dev/null || true"
ExecStart=/sbin/ip tunnel add gre${id} mode gre local ${local_ip} remote ${remote_ip} ttl 255 key ${key}
ExecStart=/sbin/ip addr add ${local_gre_ip}/30 dev gre${id}
${mtu_line}
ExecStart=/sbin/ip link set gre${id} up
ExecStop=/sbin/ip link set gre${id} down
ExecStop=/sbin/ip tunnel del gre${id}

[Install]
WantedBy=multi-user.target
EOF

  [[ $? -eq 0 ]] && add_log "GRE service created: $unit" || return 1
  return 0
}

haproxy_unit_exists() {
  systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'haproxy.service'
}

haproxy_write_main_cfg() {
  add_log "Rebuilding /etc/haproxy/haproxy.cfg (no include)"
  render

  rm -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 || true

  cat >/etc/haproxy/haproxy.cfg <<'EOF'
#HAPROXY-FOR-GRE
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 200000

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client  1m
    timeout server  1m

EOF
}

haproxy_write_gre_cfg() {
  local id="$1" target_ip="$2"
  shift 2
  local -a ports=("$@")

  mkdir -p /etc/haproxy/conf.d >/dev/null 2>&1 || true
  local cfg="/etc/haproxy/conf.d/haproxy-gre${id}.cfg"

  if [[ -f "$cfg" ]]; then
    add_log "ERROR: haproxy-gre${id}.cfg already exists."
    return 2
  fi

  add_log "Creating HAProxy config: $cfg"
  render

  : >"$cfg" || return 1

  local p
  for p in "${ports[@]}"; do
    cat >>"$cfg" <<EOF
frontend gre${id}_fe_${p}
    bind 0.0.0.0:${p}
    default_backend gre${id}_be_${p}

backend gre${id}_be_${p}
    option tcp-check
    server gre${id}_b_${p} ${target_ip}:${p} check

EOF
  done

  return 0
}

haproxy_patch_systemd() {
  local dir="/etc/systemd/system/haproxy.service.d"
  local override="${dir}/override.conf"

  if ! haproxy_unit_exists; then
    add_log "ERROR: not found haproxy service"
    return 1
  fi

  add_log "Patching systemd for haproxy to load /etc/haproxy/conf.d/ (drop-in override)"
  render

  mkdir -p "$dir" >/dev/null 2>&1 || return 1

  cat >"$override" <<'EOF'
[Service]
Environment="CONFIG=/etc/haproxy/haproxy.cfg"
Environment="PIDFILE=/run/haproxy.pid"
Environment="EXTRAOPTS=-S /run/haproxy-master.sock"
ExecStart=
ExecStart=/usr/sbin/haproxy -Ws -f $CONFIG -f /etc/haproxy/conf.d/ -p $PIDFILE $EXTRAOPTS
ExecReload=
ExecReload=/usr/sbin/haproxy -Ws -f $CONFIG -f /etc/haproxy/conf.d/ -c -q $EXTRAOPTS
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  return 0
}

haproxy_apply_and_show() {
  haproxy_patch_systemd || return 1

  add_log "Enabling HAProxy..."
  render
  systemctl enable --now haproxy >/dev/null 2>&1 || true

  add_log "Restarting HAProxy..."
  render
  systemctl restart haproxy >/dev/null 2>&1 || true

  render
  echo "---- STATUS (haproxy.service) ----"
  systemctl status haproxy --no-pager 2>&1 | sed -n '1,18p'
  echo "---------------------------------"
}



iran_setup() {
  local ID LOCAL_IPS_STR REMOTE_IPS_STR GREBASE
  local -a PORT_LIST=()

  ask_until_valid "GRE Number :" is_int ID
  ask_multiple_local_ips "Select IRAN IPs (local server):" LOCAL_IPS_STR || { die_soft "Failed to select local IPs."; return 0; }
  ask_remote_ips "Enter KHAREJ IPs (remote server):" REMOTE_IPS_STR || { die_soft "Failed to enter remote IPs."; return 0; }
  ask_until_valid "GRE IP RANG (Example: $(random_gre_base)):" valid_gre_base GREBASE
  ask_ports

  local use_mtu="n" MTU_VALUE=""

  while true; do
    render
    read -r -p "set custom mtu? (y/n): " use_mtu
    use_mtu="$(trim "$use_mtu")"
    case "${use_mtu,,}" in
      y|yes)
        ask_until_valid "input your custom mtu for gre (576-9000):" valid_mtu MTU_VALUE
        break
        ;;
      n|no|"")
        MTU_VALUE="1420"
        add_log "Using default MTU: 1420"
        break
        ;;
      *)
        add_log "Invalid input. Please enter y or n."
        ;;
    esac
  done


  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  add_log "KEY=${key} | IRAN=${local_gre_ip} | KHAREJ=${peer_gre_ip}"

  # Calculate current IP from lists
  write_sepehr_conf "$ID" "IRAN" "$LOCAL_IPS_STR" "$REMOTE_IPS_STR" "$GREBASE" "$MTU_VALUE"
  calculate_current_ips "$ID" || { die_soft "Failed to calculate IPs."; return 0; }
  local IRANIP="$CALC_LOCAL_IP"
  local KHAREJIP="$CALC_REMOTE_IP"
  add_log "Using IPs: Local=$IRANIP Remote=$KHAREJIP"

  ensure_packages || { die_soft "Package installation failed."; return 0; }

  make_gre_service "$ID" "$IRANIP" "$KHAREJIP" "$local_gre_ip" "$key" "$MTU_VALUE"
  local rc=$?
  [[ $rc -eq 2 ]] && return 0
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Starting gre${ID}..."
  enable_now "gre${ID}.service"

  add_log "Writing HAProxy configs for GRE${ID}..."
  haproxy_write_gre_cfg "$ID" "$peer_gre_ip" "${PORT_LIST[@]}"
  local hrc=$?
  if [[ $hrc -eq 2 ]]; then
    die_soft "haproxy-gre${ID}.cfg already exists."
    return 0
  elif [[ $hrc -ne 0 ]]; then
    die_soft "Failed writing haproxy-gre${ID}.cfg"
    return 0
  fi

  haproxy_write_main_cfg

  if command -v haproxy >/dev/null 2>&1; then
    haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/ >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      die_soft "HAProxy config validation failed (haproxy -c)."
      return 0
    fi
  fi

  haproxy_apply_and_show || { die_soft "Failed applying HAProxy systemd override."; return 0; }

  render
  echo "GRE IPs:"
  echo "  IRAN  : ${local_gre_ip}"
  echo "  KHAREJ: ${peer_gre_ip}"
  echo "  Public Local : ${IRANIP}"
  echo "  Public Remote: ${KHAREJIP}"
  echo "  Config: $(sepehr_conf_path "$ID")"
  echo
  echo "Status:"
  show_unit_status_brief "gre${ID}.service"
  echo

  # Auto-enable monitor for self-healing
  add_log "Enabling Self-Healing Monitor..."
  create_monitor_service "$ID" && add_log "Monitor enabled for GRE${ID}" || add_log "WARNING: Monitor setup failed"

  # Auto-enable cron for scheduled IP rotation every 30 minutes
  add_log "Enabling Auto-Rotation (30min)..."
  create_auto_cron "$ID" "IRAN"

  echo "Monitor: sepehr-monitor-gre${ID}.timer (3min failover)"
  echo "Cron: IP rotation every 30 minutes"
  pause_enter
}

kharej_setup() {
  local ID LOCAL_IPS_STR REMOTE_IPS_STR GREBASE
  local use_mtu="n" MTU_VALUE=""

  ask_until_valid "GRE Number(Like IRAN PLEASE) :" is_int ID
  ask_multiple_local_ips "Select KHAREJ IPs (local server):" LOCAL_IPS_STR || { die_soft "Failed to select local IPs."; return 0; }
  ask_remote_ips "Enter IRAN IPs (remote server):" REMOTE_IPS_STR || { die_soft "Failed to enter remote IPs."; return 0; }
  ask_until_valid "GRE IP RANG (Like IRAN - Example: $(random_gre_base)):" valid_gre_base GREBASE

  while true; do
    render
    read -r -p "set custom mtu? (y/n): " use_mtu
    use_mtu="$(trim "$use_mtu")"
    case "${use_mtu,,}" in
      y|yes)
        ask_until_valid "input your custom mtu for gre (576-9000):" valid_mtu MTU_VALUE
        break
        ;;
      n|no|"")
        MTU_VALUE="1420"
        add_log "Using default MTU: 1420"
        break
        ;;
      *)
        add_log "Invalid input. Please enter y or n."
        ;;
    esac
  done

  local key=$((ID*100))
  local local_gre_ip peer_gre_ip
  local_gre_ip="$(ipv4_set_last_octet "$GREBASE" 2)"
  peer_gre_ip="$(ipv4_set_last_octet "$GREBASE" 1)"
  add_log "KEY=${key} | KHAREJ=${local_gre_ip} | IRAN=${peer_gre_ip}"

  # Calculate current IP from lists
  write_sepehr_conf "$ID" "KHAREJ" "$LOCAL_IPS_STR" "$REMOTE_IPS_STR" "$GREBASE" "$MTU_VALUE"
  calculate_current_ips "$ID" || { die_soft "Failed to calculate IPs."; return 0; }
  local KHAREJIP="$CALC_LOCAL_IP"
  local IRANIP="$CALC_REMOTE_IP"
  add_log "Using IPs: Local=$KHAREJIP Remote=$IRANIP"

  ensure_iproute_only || { die_soft "Package installation failed (iproute2)."; return 0; }

  make_gre_service "$ID" "$KHAREJIP" "$IRANIP" "$local_gre_ip" "$key" "$MTU_VALUE"
  local rc=$?
  [[ $rc -eq 2 ]] && return 0
  [[ $rc -ne 0 ]] && { die_soft "Failed creating GRE service."; return 0; }

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Starting gre${ID}..."
  enable_now "gre${ID}.service"

  render
  echo "GRE IPs:"
  echo "  KHAREJ: ${local_gre_ip}"
  echo "  IRAN  : ${peer_gre_ip}"
  echo "  Public Local : ${KHAREJIP}"
  echo "  Public Remote: ${IRANIP}"
  echo "  Config: $(sepehr_conf_path "$ID")"
  echo
  show_unit_status_brief "gre${ID}.service"
  echo

  # Auto-enable monitor for self-healing
  add_log "Enabling Self-Healing Monitor..."
  create_monitor_service "$ID" && add_log "Monitor enabled for GRE${ID}" || add_log "WARNING: Monitor setup failed"

  # Auto-enable cron for scheduled IP rotation every 30 minutes
  add_log "Enabling Auto-Rotation (30min)..."
  create_auto_cron "$ID" "KHAREJ"

  echo "Monitor: sepehr-monitor-gre${ID}.timer (3min failover)"
  echo "Cron: IP rotation every 30 minutes"
  pause_enter
}

get_gre_ids() {
  local ids=()

  while IFS= read -r u; do
    [[ "$u" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^gre[0-9]+\.service$' || true)

  while IFS= read -r f; do
    f="$(basename "$f")"
    [[ "$f" =~ ^gre([0-9]+)\.service$ ]] && ids+=("${BASH_REMATCH[1]}")
  done < <(find /etc/systemd/system -maxdepth 1 -type f -name 'gre*.service' 2>/dev/null || true)

  printf "%s\n" "${ids[@]}" | awk 'NF{a[$0]=1} END{for(k in a) print k}' | sort -n
}

MENU_SELECTED=-1

menu_select_index() {
  local title="$1"
  local prompt="$2"
  shift 2
  local -a items=("$@")
  local choice=""

  while true; do
    render
    echo "$title"
    echo

    if ((${#items[@]} == 0)); then
      echo "No service found."
      echo
      read -r -p "Press ENTER to go back..." _
      MENU_SELECTED=-1
      return 1
    fi

    local i
    for ((i=0; i<${#items[@]}; i++)); do
      printf "%d) %s\n" $((i+1)) "${items[$i]}"
    done
    echo "0) Back"
    echo

    read -r -e -p "$prompt " choice
    choice="$(trim "$choice")"

    if [[ "$choice" == "0" ]]; then
      MENU_SELECTED=-1
      return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#items[@]})); then
      MENU_SELECTED=$((choice-1))
      return 0
    fi

    add_log "Invalid selection: $choice"
  done
}

service_action_menu() {
  local unit="$1"
  local action=""

  while true; do
    render
    echo "Selected: $unit"
    echo
    echo "1) Enable & Start"
    echo "2) Restart"
    echo "3) Stop & Disable"
    echo "4) Status"
    echo "0) Back"
    echo

    read -r -e -p "Select action: " action
    action="$(trim "$action")"

    case "$action" in
      1)
        add_log "Enable & Start: $unit"
        systemctl enable "$unit" >/dev/null 2>&1 && add_log "Enabled: $unit" || add_log "Enable failed: $unit"
        systemctl start "$unit"  >/dev/null 2>&1 && add_log "Started: $unit" || add_log "Start failed: $unit"
        ;;
      2)
        add_log "Restart: $unit"
        systemctl restart "$unit" >/dev/null 2>&1 && add_log "Restarted: $unit" || add_log "Restart failed: $unit"
        ;;
      3)
        add_log "Stop & Disable: $unit"
        systemctl stop "$unit"    >/dev/null 2>&1 && add_log "Stopped: $unit" || add_log "Stop failed: $unit"
        systemctl disable "$unit" >/dev/null 2>&1 && add_log "Disabled: $unit" || add_log "Disable failed: $unit"
        ;;
      4)
        render
        echo "---- STATUS ($unit) ----"
        systemctl --no-pager --full status "$unit" 2>&1 | sed -n '1,16p'
        echo "------------------------"
        pause_enter
        ;;
      0) return 0 ;;
      *) add_log "Invalid action: $action" ;;
    esac
  done
}

services_management() {
  local sel=""

  while true; do
    render
    echo "Services ManageMent"
    echo
    echo "1) GRE"
    echo "2) HAPROXY"
    echo "0) Back"
    echo
    read -r -e -p "Select: " sel
    sel="$(trim "$sel")"

    case "$sel" in
      1)
        mapfile -t GRE_IDS < <(get_gre_ids)
        local -a GRE_LABELS=()
        local id
        for id in "${GRE_IDS[@]}"; do
          GRE_LABELS+=("GRE${id}")
        done

        if menu_select_index "GRE Services" "Select GRE:" "${GRE_LABELS[@]}"; then
          local idx="$MENU_SELECTED"
          id="${GRE_IDS[$idx]}"
          add_log "GRE selected: GRE${id}"
          service_action_menu "gre${id}.service"
        fi
        ;;

      2)
        if ! haproxy_unit_exists; then
          add_log "ERROR: not found haproxy service"
          render
          pause_enter
          continue
        fi
        add_log "HAProxy selected"
        service_action_menu "haproxy.service"
        ;;

      0) return 0 ;;
      *) add_log "Invalid selection: $sel" ;;
    esac
  done
}

uninstall_clean() {
  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do
    GRE_LABELS+=("GRE${id}")
  done

  if ! menu_select_index "Uninstall & Clean" "Select GRE to uninstall:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"

  while true; do
    render
    echo "Uninstall & Clean"
    echo
    echo "Target: GRE${id}"
    echo "This will remove:"
    echo "  - /etc/systemd/system/gre${id}.service"
    echo "  - /etc/haproxy/conf.d/haproxy-gre${id}.cfg (if exists)"
    echo "  - /etc/haproxy/conf.d/gre${id}.cfg (if exists)"
    echo "  - cron + /usr/local/bin/sepehr-recreate-gre${id}.sh (if exists)"
    echo "  - /var/log/sepehr-gre${id}.log (if exists)"
    echo "  - /root/gre-backup/* for this GRE (if exists)"
    echo
    echo "Type: YES (confirm)  or  NO (cancel)"
    echo
    local confirm=""
    read -r -e -p "Confirm: " confirm
    confirm="$(trim "$confirm")"

    if [[ "$confirm" == "NO" || "$confirm" == "no" ]]; then
      add_log "Uninstall cancelled for GRE${id}"
      return 0
    fi
    if [[ "$confirm" == "YES" ]]; then
      break
    fi
    add_log "Please type YES or NO."
  done

  add_log "Stopping gre${id}.service"
  systemctl stop "gre${id}.service" >/dev/null 2>&1 || true
  add_log "Disabling gre${id}.service"
  systemctl disable "gre${id}.service" >/dev/null 2>&1 || true

  add_log "Removing unit file..."
  rm -f "/etc/systemd/system/gre${id}.service" >/dev/null 2>&1 || true

  add_log "Removing HAProxy GRE config (if exists)..."
  rm -f "/etc/haproxy/conf.d/haproxy-gre${id}.cfg" >/dev/null 2>&1 || true
  rm -f "/etc/haproxy/conf.d/gre${id}.cfg" >/dev/null 2>&1 || true

  add_log "Reloading systemd..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed  >/dev/null 2>&1 || true

  if haproxy_unit_exists; then
    add_log "Restarting haproxy (no disable)..."
    systemctl restart haproxy >/dev/null 2>&1 || true
  else
    add_log "haproxy service not found; skip restart."
  fi

  add_log "Removing automation (cron/script/log/backup) for GRE${id}..."

  remove_gre_automation_cron "$id"
  add_log "Cron entry removed (if existed)."

  local a_script a_log
  a_script="$(automation_script_path "$id")"
  a_log="$(automation_log_path "$id")"

  if [[ -f "$a_script" ]]; then
    rm -f "$a_script" >/dev/null 2>&1 || true
    add_log "Removed: $a_script"
  else
    add_log "No automation script found."
  fi

  if [[ -f "$a_log" ]]; then
    rm -f "$a_log" >/dev/null 2>&1 || true
    add_log "Removed: $a_log"
  else
    add_log "No automation log found."
  fi

  remove_gre_automation_backups "$id"

  add_log "Uninstall completed for GRE${id}"
  render
  pause_enter
}

get_gre_local_ip_cidr() {
  local id="$1"
  ip -4 -o addr show dev "gre${id}" 2>/dev/null | awk '{print $4}' | head -n1
}

get_peer_ip_from_local_cidr() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local mask="${cidr#*/}"

  IFS='.' read -r a b c d <<<"$ip"

  local peer_d
  if [[ "$d" == "1" ]]; then
    peer_d="2"
  elif [[ "$d" == "2" ]]; then
    peer_d="1"
  else
    peer_d="2"
  fi

  echo "${a}.${b}.${c}.${peer_d}"
}

haproxy_add_ports_to_gre_cfg() {
  local id="$1" target_ip="$2"
  shift 2
  local -a ports=("$@")
  local cfg="/etc/haproxy/conf.d/haproxy-gre${id}.cfg"

  if [[ ! -f "$cfg" ]]; then
    add_log "ERROR: Not found: $cfg"
    return 1
  fi

  add_log "Editing HAProxy config: $cfg"
  render

  local p added=0 skipped=0
  for p in "${ports[@]}"; do
    if grep -qE "^frontend[[:space:]]+gre${id}_fe_${p}\b" "$cfg" 2>/dev/null; then
      add_log "Skip (exists): GRE${id} port ${p}"
      ((skipped++))
      continue
    fi

    cat >>"$cfg" <<EOF

frontend gre${id}_fe_${p}
    bind 0.0.0.0:${p}
    default_backend gre${id}_be_${p}

backend gre${id}_be_${p}
    option tcp-check
    server gre${id}_b_${p} ${target_ip}:${p} check
EOF

    add_log "Added: GRE${id} port ${p} -> ${target_ip}:${p}"
    ((added++))
  done

  add_log "Done. Added=${added}, Skipped=${skipped}"
  return 0
}

add_tunnel_port() {
  render
  add_log "Selected: add tunnel port"
  render

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  local id
  for id in "${GRE_IDS[@]}"; do
    GRE_LABELS+=("GRE${id}")
  done

  if ! menu_select_index "Add Tunnel Port" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi

  local idx="$MENU_SELECTED"
  id="${GRE_IDS[$idx]}"
  add_log "GRE selected: GRE${id}"
  render

  local cidr
  cidr="$(get_gre_local_ip_cidr "$id")"
  if [[ -z "$cidr" ]]; then
    die_soft "Could not detect IP on gre${id}. Is it up and has an IP?"
    return 0
  fi

  local peer_ip
  peer_ip="$(get_peer_ip_from_local_cidr "$cidr")"
  add_log "Detected: gre${id} local=${cidr} | peer=${peer_ip}"
  render

  PORT_LIST=()
  ask_ports

  haproxy_add_ports_to_gre_cfg "$id" "$peer_ip" "${PORT_LIST[@]}" || { die_soft "Failed editing haproxy-gre${id}.cfg"; return 0; }

  if command -v haproxy >/dev/null 2>&1; then
    haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/ >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      die_soft "HAProxy config validation failed (haproxy -c)."
      return 0
    fi
  fi

  if haproxy_unit_exists; then
    add_log "Restarting HAProxy..."
    render
    systemctl restart haproxy >/dev/null 2>&1 || true
    add_log "HAProxy restarted."
  else
    add_log "WARNING: haproxy.service not found; skipped restart."
  fi

  render
  echo "GRE${id} updated."
  echo "Local CIDR : ${cidr}"
  echo "Peer IP    : ${peer_ip}"
  echo "Ports added: ${PORT_LIST[*]}"
  echo
  echo "---- STATUS (haproxy.service) ----"
  systemctl status haproxy --no-pager 2>&1 | sed -n '1,16p'
  echo "---------------------------------"
  pause_enter
}

select_and_set_timezone() {
  local tz="Asia/Tehran"

  add_log "Setting timezone: $tz (locked to Tehran)"
  render

  timedatectl set-timezone "$tz" >/dev/null 2>&1 || { add_log "ERROR: failed set-timezone"; return 1; }
  timedatectl set-ntp true >/dev/null 2>&1 || { add_log "ERROR: failed set-ntp true"; return 1; }

  local now
  now="$(TZ="$tz" date '+%Y-%m-%d %H:%M %Z')"
  add_log "Timezone set OK: $tz | Now: $now"
  return 0
}


recreate_automation() {
  local id side

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Regenerate Automation" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  while true; do
    render
    echo "Select Side"
    echo "1) IRAN SIDE"
    echo "2) KHAREJ SIDE"
    echo
    read -r -p "Select: " side
    case "$side" in
      1) side="IRAN"; break ;;
      2) side="KHAREJ"; break ;;
      *) add_log "Invalid side" ;;
    esac
  done

  # Update SIDE in config
  local conf
  conf="$(sepehr_conf_path "$id")"
  if [[ -f "$conf" ]]; then
    sed -i "s/^SIDE=.*/SIDE=\"${side}\"/" "$conf"
  fi

  select_and_set_timezone || { die_soft "Timezone/NTP setup failed."; return 0; }

  # Use unified create_auto_cron function
  create_auto_cron "$id" "$side"

  add_log "Automation Regenerated for GRE${id}"
  pause_enter
}

automation_backup_dir() {
  echo "/root/gre-backup"
}

automation_script_path() {
  local id="$1"
  echo "/usr/local/bin/sepehr-recreate-gre${id}.sh"
}

automation_log_path() {
  local id="$1"
  echo "/var/log/sepehr-gre${id}.log"
}

remove_gre_automation_cron() {
  local id="$1"
  local script
  script="$(automation_script_path "$id")"

  crontab -l >/dev/null 2>&1 || return 0

  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -vF "$script" > "$tmp" || true
  crontab "$tmp" 2>/dev/null || true
  rm -f "$tmp" >/dev/null 2>&1 || true
}

remove_gre_automation_backups() {
  local id="$1"
  local bakdir
  bakdir="$(automation_backup_dir)"

  [[ -d "$bakdir" ]] || { add_log "Backup dir not found: $bakdir"; return 0; }

  local removed_any=0

  if [[ -f "$bakdir/gre${id}.service" ]]; then
    rm -f "$bakdir/gre${id}.service" >/dev/null 2>&1 || true
    add_log "Removed backup: $bakdir/gre${id}.service"
    removed_any=1
  fi

  if [[ -f "$bakdir/haproxy-gre${id}.cfg" ]]; then
    rm -f "$bakdir/haproxy-gre${id}.cfg" >/dev/null 2>&1 || true
    add_log "Removed backup: $bakdir/haproxy-gre${id}.cfg"
    removed_any=1
  fi

  if [[ -f "$bakdir/gre${id}.cfg" ]]; then
    rm -f "$bakdir/gre${id}.cfg" >/dev/null 2>&1 || true
    add_log "Removed backup: $bakdir/gre${id}.cfg"
    removed_any=1
  fi

  [[ $removed_any -eq 0 ]] && add_log "No backup files found for GRE${id}."
}



recreate_automation_mode() {
  local id side

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Rebuild Automation" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  while true; do
    render
    echo "Select Side"
    echo "1) IRAN SIDE"
    echo "2) KHAREJ SIDE"
    echo
    read -r -p "Select: " side
    case "$side" in
      1) side="IRAN"; break ;;
      2) side="KHAREJ"; break ;;
      *) add_log "Invalid side" ;;
    esac
  done

  # Update SIDE in config
  local conf
  conf="$(sepehr_conf_path "$id")"
  if [[ -f "$conf" ]]; then
    sed -i "s/^SIDE=.*/SIDE=\"${side}\"/" "$conf"
  fi

  select_and_set_timezone || { die_soft "Timezone/NTP setup failed."; return 0; }

  # Use unified create_auto_cron function
  create_auto_cron "$id" "$side"

  add_log "Automation Rebuild for GRE${id}"
  pause_enter
}

change_mtu() {
  local id mtu

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Change MTU" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  ask_until_valid "input your new mtu for gre (576-9000):" valid_mtu mtu

  add_log "Setting MTU on interface gre${id} to ${mtu}..."
  render
  ip link set "gre${id}" mtu "$mtu" >/dev/null 2>&1 || add_log "WARNING: gre${id} interface not found or not up (will still patch unit)."

  local unit="/etc/systemd/system/gre${id}.service"
  local backup="/root/gre-backup/gre${id}.service"

  add_log "Patching unit file: $unit"
  render
  if [[ -f "$unit" ]]; then
    ensure_mtu_line_in_unit "$id" "$mtu" "$unit"
  else
    die_soft "Unit file not found: $unit"
    return 0
  fi

  if [[ -f "$backup" ]]; then
    add_log "Patching backup unit: $backup"
    render
    ensure_mtu_line_in_unit "$id" "$mtu" "$backup"
  else
    add_log "No backup unit found (skip): $backup"
  fi

  add_log "Reloading systemd..."
  systemd_reload

  add_log "Restarting gre${id}.service..."
  systemctl restart "gre${id}.service" >/dev/null 2>&1 || add_log "WARNING: restart failed for gre${id}.service"

  add_log "Done: GRE${id} MTU changed to ${mtu}"
  render
  pause_enter
}


edit_tunnel_ips() {
  local id

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Edit Tunnel IPs" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  local unit="/etc/systemd/system/gre${id}.service"
  if [[ ! -f "$unit" ]]; then
    die_soft "Unit file not found: $unit"
    return 0
  fi

  local old_local old_remote
  old_local=$(grep -oP 'ip tunnel add gre[0-9]+ mode gre local \K[0-9.]+' "$unit" | head -n1)
  old_remote=$(grep -oP 'remote \K[0-9.]+' "$unit" | head -n1)

  add_log "Current: Local=${old_local} Remote=${old_remote}"
  render

  local what_to_edit
  while true; do
    render
    echo "Edit Tunnel GRE${id}"
    echo "Current: Local=${old_local} | Remote=${old_remote}"
    echo
    echo "1) Change Local IP (this server)"
    echo "2) Change Remote IP (other server)"
    echo "3) Change Both"
    echo "0) Back"
    echo
    read -r -e -p "Select: " what_to_edit
    what_to_edit="$(trim "$what_to_edit")"
    case "$what_to_edit" in
      1|2|3) break ;;
      0) return 0 ;;
      *) add_log "Invalid selection" ;;
    esac
  done

  local new_local="$old_local" new_remote="$old_remote"

  if [[ "$what_to_edit" == "1" || "$what_to_edit" == "3" ]]; then
    select_local_ip "Select NEW Local IP:" new_local || { die_soft "Failed to select local IP."; return 0; }
  fi

  if [[ "$what_to_edit" == "2" || "$what_to_edit" == "3" ]]; then
    ask_until_valid "Enter NEW Remote IP:" valid_ipv4 new_remote
  fi

  add_log "Updating: Local ${old_local} -> ${new_local} | Remote ${old_remote} -> ${new_remote}"
  render

  sed -i.bak -E "s/(ip tunnel add gre${id} mode gre local )[0-9.]+/\\1${new_local}/" "$unit"
  sed -i -E "s/(remote )[0-9.]+ (ttl)/\\1${new_remote} \\2/" "$unit"

  local backup="/root/gre-backup/gre${id}.service"
  if [[ -f "$backup" ]]; then
    add_log "Updating backup: $backup"
    sed -i.bak -E "s/(ip tunnel add gre${id} mode gre local )[0-9.]+/\\1${new_local}/" "$backup"
    sed -i -E "s/(remote )[0-9.]+ (ttl)/\\1${new_remote} \\2/" "$backup"
  fi

  # Update config file if exists
  local conf
  conf="$(sepehr_conf_path "$id")"
  if [[ -f "$conf" ]]; then
    add_log "Updating config: $conf"
    sed -i "s/^LOCAL_IPS=.*/LOCAL_IPS=\"${new_local}\"/" "$conf"
    sed -i "s/^REMOTE_IPS=.*/REMOTE_IPS=\"${new_remote}\"/" "$conf"
    sed -i "s/^OFFSET=.*/OFFSET=0/" "$conf"
    add_log "Config updated - OFFSET reset to 0"
  fi

  add_log "Reloading systemd..."
  systemctl daemon-reload >/dev/null 2>&1 || true

  add_log "Restarting gre${id}.service..."
  systemctl restart "gre${id}.service" >/dev/null 2>&1 || add_log "WARNING: restart failed"

  add_log "Done: GRE${id} IPs updated."
  render
  echo "GRE${id} Updated:"
  echo "  Local : ${old_local} -> ${new_local}"
  echo "  Remote: ${old_remote} -> ${new_remote}"
  echo
  show_unit_status_brief "gre${id}.service"
  pause_enter
}

view_ip_state() {
  local id

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "View IP State" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  local conf
  conf="$(sepehr_conf_path "$id")"
  if [[ ! -f "$conf" ]]; then
    render
    echo "No config found: $conf"
    echo "This tunnel may have been created without multi-IP support."
    pause_enter
    return 0
  fi

  source "$conf"
  calculate_current_ips "$id"

  render
  echo "═══════════════════════════════════════════════════════"
  echo "             GRE${id} IP STATE"
  echo "═══════════════════════════════════════════════════════"
  echo
  echo "  SIDE: ${SIDE}"
  echo
  echo "  LOCAL IPs : ${LOCAL_IPS}"
  echo "  REMOTE IPs: ${REMOTE_IPS}"
  echo
  echo "  CURRENT OFFSET: ${OFFSET}"
  echo
  echo "  ─────────────────────────────────────────────────────"
  echo "  CALCULATED (active now):"
  echo "    Local IP : ${CALC_LOCAL_IP}"
  echo "    Remote IP: ${CALC_REMOTE_IP}"
  echo "  ─────────────────────────────────────────────────────"
  echo
  echo "  GRE BASE: ${GRE_BASE}"
  echo "  MTU: ${MTU:-default}"
  echo "  FAIL COUNT: ${FAIL_COUNT}"
  echo "  LAST SUCCESS: $(date -d @${LAST_SUCCESS} '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo $LAST_SUCCESS)"
  echo
  echo "  Config file: $conf"
  echo
  echo "═══════════════════════════════════════════════════════"
  pause_enter
}

create_monitor_service() {
  local id="$1"
  local script="/usr/local/bin/sepehr-monitor-gre${id}.sh"
  local service="/etc/systemd/system/sepehr-monitor-gre${id}.service"
  local timer="/etc/systemd/system/sepehr-monitor-gre${id}.timer"

  local conf
  conf="$(sepehr_conf_path "$id")"
  if [[ ! -f "$conf" ]]; then
    add_log "ERROR: Config not found: $conf"
    return 1
  fi

  add_log "Creating monitor script: $script"
  cat >"$script" <<'MONITOR_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

ID="__ID__"
CONF="__CONF__"
UNIT="/etc/systemd/system/gre__ID__.service"
LOG_FILE="/var/log/sepehr-monitor-gre__ID__.log"
MAX_FAILS=3

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

[[ -f "$CONF" ]] || { log "ERROR: Config not found: $CONF"; exit 1; }
source "$CONF"

# Get current local GRE IP from service file and calculate peer
LOCAL_GRE_IP=$(grep -oP 'ip addr add \K[0-9.]+' "$UNIT" 2>/dev/null | head -n1 || true)
if [[ -z "$LOCAL_GRE_IP" ]]; then
  log "ERROR: Cannot detect local GRE IP from $UNIT"
  exit 1
fi

# Calculate peer IP (change last octet: .1 -> .2, .2 -> .1)
GRE_PREFIX="${LOCAL_GRE_IP%.*}"
LAST_OCTET="${LOCAL_GRE_IP##*.}"
if [[ "$LAST_OCTET" == "1" ]]; then
  PEER_GRE_IP="${GRE_PREFIX}.2"
else
  PEER_GRE_IP="${GRE_PREFIX}.1"
fi

# Ping test
if ping -c 2 -W 3 "$PEER_GRE_IP" >/dev/null 2>&1; then
  # Success - reset fail count
  if [[ "${FAIL_COUNT:-0}" != "0" ]]; then
    sed -i "s/^FAIL_COUNT=.*/FAIL_COUNT=0/" "$CONF"
    sed -i "s/^LAST_SUCCESS=.*/LAST_SUCCESS=$(date +%s)/" "$CONF"
    log "Connection OK - fail count reset"
  fi
  exit 0
fi

# Failed - increment fail count
source "$CONF"
NEW_FAIL=$((FAIL_COUNT + 1))
sed -i "s/^FAIL_COUNT=.*/FAIL_COUNT=${NEW_FAIL}/" "$CONF"
log "Ping failed (${NEW_FAIL}/${MAX_FAILS})"

if ((NEW_FAIL >= MAX_FAILS)); then
  # Blacklist current path and let cron select next active path
  log "MAX FAILS reached - blacklisting current path"

  # Get current public IPs from service file
  CURRENT_LOCAL=$(grep -oP 'ip tunnel add gre[0-9]+ mode gre local \K[0-9.]+' "$UNIT" 2>/dev/null | head -n1 || true)
  CURRENT_REMOTE=$(grep -oP 'remote \K[0-9.]+' "$UNIT" 2>/dev/null | head -n1 || true)

  if [[ -n "$CURRENT_LOCAL" && -n "$CURRENT_REMOTE" ]]; then
    source "$CONF"
    IFS=',' read -r -a local_arr <<< "$LOCAL_IPS"
    IFS=',' read -r -a remote_arr <<< "$REMOTE_IPS"

    local_count=${#local_arr[@]}
    remote_count=${#remote_arr[@]}

    # Find current path index
    local_idx=-1
    remote_idx=-1
    for ((i=0; i<local_count; i++)); do
      [[ "${local_arr[$i]}" == "$CURRENT_LOCAL" ]] && local_idx=$i && break
    done
    for ((i=0; i<remote_count; i++)); do
      [[ "${remote_arr[$i]}" == "$CURRENT_REMOTE" ]] && remote_idx=$i && break
    done

    if ((local_idx >= 0 && remote_idx >= 0)); then
      path_index=$((local_idx * remote_count + remote_idx))

      # Add to blacklist if not already there
      current_blacklist="${BLACKLIST:-}"
      if [[ -z "$current_blacklist" ]]; then
        new_blacklist="$path_index"
      elif [[ ! ",$current_blacklist," =~ ,$path_index, ]]; then
        new_blacklist="${current_blacklist},${path_index}"
      else
        new_blacklist="$current_blacklist"
      fi

      sed -i "s/^BLACKLIST=.*/BLACKLIST=\"${new_blacklist}\"/" "$CONF"
      log "Blacklisted path $path_index (${CURRENT_LOCAL} -> ${CURRENT_REMOTE})"
    fi
  fi

  sed -i "s/^FAIL_COUNT=.*/FAIL_COUNT=0/" "$CONF"

  # Restart tunnel - cron will select next active path
  if [[ -f "$UNIT" ]]; then
    systemctl daemon-reload
    systemctl restart "gre$ID.service"
    log "GRE$ID restarted"

    # Restart haproxy if IRAN side
    if [[ "$SIDE" == "IRAN" ]]; then
      systemctl restart haproxy 2>/dev/null || true
      log "HAProxy restarted"
    fi
  fi
fi
MONITOR_SCRIPT

  sed -i "s|__ID__|${id}|g" "$script"
  sed -i "s|__CONF__|${conf}|g" "$script"
  chmod +x "$script"

  add_log "Creating systemd service: $service"
  cat >"$service" <<EOF
[Unit]
Description=Sepehr GRE${id} Monitor

[Service]
Type=oneshot
ExecStart=${script}
EOF

  add_log "Creating systemd timer: $timer"
  cat >"$timer" <<EOF
[Unit]
Description=Sepehr GRE${id} Monitor Timer

[Timer]
OnBootSec=60
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "sepehr-monitor-gre${id}.timer" >/dev/null 2>&1 || true

  add_log "Monitor enabled for GRE${id}"
  return 0
}

setup_monitor() {
  local id

  mapfile -t GRE_IDS < <(get_gre_ids)
  local -a GRE_LABELS=()
  for id in "${GRE_IDS[@]}"; do GRE_LABELS+=("GRE${id}"); done

  if ! menu_select_index "Setup Monitor (Self-Healing)" "Select GRE:" "${GRE_LABELS[@]}"; then
    return 0
  fi
  id="${GRE_IDS[$MENU_SELECTED]}"

  create_monitor_service "$id" || { die_soft "Failed to create monitor service."; return 0; }

  render
  echo "Monitor Setup Complete for GRE${id}"
  echo
  echo "  Script: /usr/local/bin/sepehr-monitor-gre${id}.sh"
  echo "  Timer : sepehr-monitor-gre${id}.timer"
  echo "  Log   : /var/log/sepehr-monitor-gre${id}.log"
  echo
  echo "The monitor will:"
  echo "  1. Check tunnel connectivity every 60 seconds"
  echo "  2. After 3 failures, blacklist current path"
  echo "  3. Cron will automatically select next active path"
  echo
  show_unit_status_brief "sepehr-monitor-gre${id}.timer"
  pause_enter
}

show_tunnels_status() {
  local -a gre_ids=()
  mapfile -t gre_ids < <(get_gre_ids)

  if ((${#gre_ids[@]} == 0)); then
    return 0
  fi

  echo "┌───────────────────────────────── ACTIVE TUNNELS ─────────────────────────────────┐"
  local id unit conf local_ip remote_ip gre_local_ip gre_remote_ip side status gre_base
  for id in "${gre_ids[@]}"; do
    unit="/etc/systemd/system/gre${id}.service"
    conf="/etc/sepehr/gre${id}.conf"

    # Get public IPs and GRE local IP from unit file
    if [[ -f "$unit" ]]; then
      local_ip=$(grep -oP 'ip tunnel add gre[0-9]+ mode gre local \K[0-9.]+' "$unit" 2>/dev/null | head -n1 || echo "?")
      remote_ip=$(grep -oP 'remote \K[0-9.]+' "$unit" 2>/dev/null | head -n1 || echo "?")
      gre_local_ip=$(grep -oP 'ip addr add \K[0-9.]+' "$unit" 2>/dev/null | head -n1 || echo "?")
    else
      local_ip="?"
      remote_ip="?"
      gre_local_ip="?"
    fi

    # Get side and calculate peer GRE IP based on actual local GRE IP
    gre_remote_ip="?"
    if [[ -f "$conf" ]]; then
      source "$conf"
      side="${SIDE:-?}"
      # Calculate peer from actual local GRE IP (change last octet)
      if [[ "$gre_local_ip" != "?" ]]; then
        local gre_prefix="${gre_local_ip%.*}"
        if [[ "$side" == "IRAN" ]]; then
          # IRAN is .1, peer (KHAREJ) is .2
          gre_remote_ip="${gre_prefix}.2"
        else
          # KHAREJ is .2, peer (IRAN) is .1
          gre_remote_ip="${gre_prefix}.1"
        fi
      fi
    else
      side="?"
    fi

    if systemctl is-active "gre${id}.service" >/dev/null 2>&1; then
      status="●"
    else
      status="○"
    fi

    printf "│ %s GRE%-4s %-6s %-15s (%-12s) → %-15s (%-12s) │\n" \
      "$status" "$id" "$side" "$local_ip" "$gre_local_ip" "$remote_ip" "$gre_remote_ip"
  done
  echo "└──────────────────────────────────────────────────────────────────────────────────┘"
  echo
}

fix_all_tunnels() {
  render
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║           FIX ALL TUNNELS - Update Scripts                   ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo

  mapfile -t GRE_IDS < <(get_gre_ids)

  if ((${#GRE_IDS[@]} == 0)); then
    add_log "No tunnels found."
    pause_enter
    return 0
  fi

  echo "Found ${#GRE_IDS[@]} tunnel(s): ${GRE_IDS[*]}"
  echo
  echo "This will:"
  echo "  1. Reset BLACKLIST for all tunnels"
  echo "  2. Recreate rotation scripts with new code"
  echo "  3. Recreate monitors with new code"
  echo "  4. Fix HAProxy configs (IRAN side only)"
  echo
  read -r -p "Continue? (y/n): " confirm
  [[ "${confirm,,}" != "y" ]] && return 0

  local id conf side
  for id in "${GRE_IDS[@]}"; do
    conf="$(sepehr_conf_path "$id")"

    if [[ -f "$conf" ]]; then
      source "$conf"
      side="${SIDE:-KHAREJ}"

      echo
      add_log "Fixing GRE${id} (${side})..."

      # 1. Reset BLACKLIST and FAIL_COUNT
      sed -i 's/^BLACKLIST=.*/BLACKLIST=""/' "$conf"
      sed -i "s/^FAIL_COUNT=.*/FAIL_COUNT=0/" "$conf"
      add_log "  Reset BLACKLIST and FAIL_COUNT"

      # 2. Recreate rotation script
      create_auto_cron "$id" "$side"
      add_log "  Recreated rotation script"

      # 3. Recreate monitor
      create_monitor_service "$id"
      add_log "  Recreated monitor"

      # 4. Fix HAProxy if IRAN
      if [[ "$side" == "IRAN" ]]; then
        local hap_cfg="/etc/haproxy/conf.d/haproxy-gre${id}.cfg"
        if [[ -f "$hap_cfg" ]]; then
          # Change .1 to .2 in backend
          sed -i 's/\([0-9]\+\.[0-9]\+\.[0-9]\+\.\)1:/\12:/g' "$hap_cfg"
          add_log "  Fixed HAProxy peer IP"
        fi
      fi

      add_log "  ✓ GRE${id} fixed"
    else
      add_log "  ✗ Config not found for GRE${id}"
    fi
  done

  # Restart HAProxy if any IRAN side
  if systemctl is-active haproxy >/dev/null 2>&1; then
    systemctl restart haproxy 2>/dev/null || true
    add_log "HAProxy restarted"
  fi

  echo
  add_log "All tunnels fixed!"
  pause_enter
}

main_menu() {
  local choice=""
  while true; do
    render
    show_tunnels_status
    echo "1 > IRAN SETUP"
    echo "2 > KHAREJ SETUP"
    echo "3 > Services ManageMent"
    echo "4 > Unistall & Clean"
    echo "5 > ADD TUNNEL PORT"
    echo "6 > Rebuild Automation"
    echo "7 > Regenerate Automation"
    echo "8 > Change MTU"
    echo "9 > Edit Tunnel IPs"
    echo "10> View IP State"
    echo "11> Setup Monitor (Self-Healing)"
    echo "12> Fix All Tunnels (Update Scripts)"
    echo "0 > Exit"
    echo
    read -r -e -p "Select option: " choice
    choice="$(trim "$choice")"

    case "$choice" in
      1) add_log "Selected: IRAN SETUP"; iran_setup ;;
      2) add_log "Selected: KHAREJ SETUP"; kharej_setup ;;
      3) add_log "Selected: Services ManageMent"; services_management ;;
      4) add_log "Selected: Unistall & Clean"; uninstall_clean ;;
      5) add_log "Selected: add tunnel port"; add_tunnel_port ;;
      6) add_log "Selected: Rebuild Automation"; recreate_automation_mode ;;
      7) add_log "Selected: Regenerate Automation"; recreate_automation ;;
      8) add_log "Selected: change mtu"; change_mtu ;;
      9) add_log "Selected: Edit Tunnel IPs"; edit_tunnel_ips ;;
      10) add_log "Selected: View IP State"; view_ip_state ;;
      11) add_log "Selected: Setup Monitor"; setup_monitor ;;
      12) add_log "Selected: Fix All Tunnels"; fix_all_tunnels ;;
      0) add_log "Bye!"; render; exit 0 ;;
      *) add_log "Invalid option: $choice" ;;
    esac
  done
}

ensure_root "$@"
add_log "SEPEHR GRE+FORWARDER installer (HAProxy mode)."
main_menu


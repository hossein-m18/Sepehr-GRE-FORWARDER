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
      # Canonical path index is always based on [IRAN x KHAREJ].
      if [[ "$SIDE" == "KHAREJ" ]]; then
        # local_idx = kharej_idx, remote_idx = iran_idx
        path_index=$((remote_idx * local_count + local_idx))
      else
        # local_idx = iran_idx, remote_idx = kharej_idx
        path_index=$((local_idx * remote_count + remote_idx))
      fi

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
  sed -i "s/^LAST_SUCCESS=.*/LAST_SUCCESS=$(date +%s)/" "$CONF"

  # Apply replacement immediately using the same deterministic selector.
  if [[ -x "$ROTATOR" ]]; then
    if "$ROTATOR" >/dev/null 2>&1; then
      log "Switched to next active path via rotator"
    else
      log "ERROR: Rotator failed: $ROTATOR"
    fi
  else
    log "WARNING: Rotator not found: $ROTATOR"
    if [[ -f "$UNIT" ]]; then
      systemctl daemon-reload
      systemctl restart "gre$ID.service"
      log "GRE$ID restarted (fallback)"
    fi
  fi

  # Restart haproxy if IRAN side
  if [[ "$SIDE" == "IRAN" ]]; then
    systemctl restart haproxy 2>/dev/null || true
    log "HAProxy restarted"
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
  echo "  3. Immediately switch to next active path"
  echo "  4. Cron still enforces rotation every 30 minutes"
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
  echo "  1. Reset BLACKLIST/FAIL_COUNT"
  echo "  2. Rebuild rotation + monitor scripts with new code"
  echo "  3. Detect/repair SIDE from current GRE local IP"
  echo "  4. Apply new algorithm immediately (no wait for cron)"
  echo "  5. Fix HAProxy configs (IRAN side only)"
  echo
  read -r -p "Continue? (y/n): " confirm
  [[ "${confirm,,}" != "y" ]] && return 0

  local id conf side unit unit_gre_ip unit_last rotator hap_cfg_guess
  for id in "${GRE_IDS[@]}"; do
    conf="$(sepehr_conf_path "$id")"

    if [[ -f "$conf" ]]; then
      source "$conf"
      side="${SIDE:-}"
      unit="/etc/systemd/system/gre${id}.service"
      hap_cfg_guess="/etc/haproxy/conf.d/haproxy-gre${id}.cfg"
      unit_gre_ip=""

      # Resolve side only when config SIDE is missing/invalid.
      if [[ "$side" != "IRAN" && "$side" != "KHAREJ" && -f "$hap_cfg_guess" ]]; then
        side="IRAN"
      fi
      if [[ "$side" != "IRAN" && "$side" != "KHAREJ" && -f "$unit" ]]; then
        unit_gre_ip=$(grep -oP 'ip addr add \K[0-9.]+' "$unit" 2>/dev/null | head -n1 || true)
        unit_last="${unit_gre_ip##*.}"
        if [[ "$unit_last" == "1" ]]; then
          side="IRAN"
        elif [[ "$unit_last" == "2" ]]; then
          side="KHAREJ"
        fi
      fi
      [[ "$side" == "IRAN" || "$side" == "KHAREJ" ]] || side="KHAREJ"

      echo
      add_log "Fixing GRE${id} (${side})..."

      # Keep config side aligned with detected side.
      if grep -q '^SIDE=' "$conf"; then
        sed -i "s/^SIDE=.*/SIDE=\"${side}\"/" "$conf"
      else
        printf 'SIDE="%s"\n' "$side" >>"$conf"
      fi

      # 1. Reset BLACKLIST and FAIL_COUNT
      if grep -q '^BLACKLIST=' "$conf"; then
        sed -i 's/^BLACKLIST=.*/BLACKLIST=""/' "$conf"
      else
        printf 'BLACKLIST=""\n' >>"$conf"
      fi
      if grep -q '^FAIL_COUNT=' "$conf"; then
        sed -i "s/^FAIL_COUNT=.*/FAIL_COUNT=0/" "$conf"
      else
        printf 'FAIL_COUNT=0\n' >>"$conf"
      fi
      if grep -q '^LAST_SUCCESS=' "$conf"; then
        sed -i "s/^LAST_SUCCESS=.*/LAST_SUCCESS=$(date +%s)/" "$conf"
      else
        printf 'LAST_SUCCESS=%s\n' "$(date +%s)" >>"$conf"
      fi
      add_log "  Reset BLACKLIST/FAIL_COUNT"

      # 2. Recreate rotation script
      create_auto_cron "$id" "$side" && add_log "  Recreated rotation script" || add_log "  WARNING: Failed to recreate rotation script"

      # 3. Recreate monitor
      create_monitor_service "$id" && add_log "  Recreated monitor" || add_log "  WARNING: Failed to recreate monitor"

      # 4. Apply immediately so old tunnels are aligned right now.
      rotator="/usr/local/bin/sepehr-recreate-gre${id}.sh"
      if [[ -x "$rotator" ]]; then
        if "$rotator" >/dev/null 2>&1; then
          add_log "  Applied new algorithm immediately"
        else
          add_log "  WARNING: Immediate apply failed (${rotator})"
          systemctl restart "gre${id}.service" >/dev/null 2>&1 || true
        fi
      else
        add_log "  WARNING: Rotator script missing (${rotator})"
      fi

      # 5. Fix HAProxy if IRAN
      if [[ "$side" == "IRAN" ]]; then
        local hap_cfg="$hap_cfg_guess"
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

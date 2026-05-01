#!/bin/bash
# =============================================================================
# unraid-stats2mqtt - Main MQTT publishing daemon
# Publishes Unraid metrics to MQTT in Home Assistant discovery format
# =============================================================================

CONFIG_FILE="/boot/config/plugins/unraid-stats2mqtt/config.cfg"
STATE_DIR="/tmp/unraid-stats2mqtt"
LOG_FILE="/var/log/unraid-stats2mqtt.log"
PID_FILE="/var/run/unraid-stats2mqtt.pid"

mkdir -p "$STATE_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/mqtt.sh"
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/ha_discovery.sh"
source "$SCRIPT_DIR/lib/loop.sh"
source "$SCRIPT_DIR/lib/api.sh"
source "$SCRIPT_DIR/metrics/var_ini.sh"
source "$SCRIPT_DIR/metrics/disks_ini.sh"
source "$SCRIPT_DIR/metrics/monitor_ini.sh"
source "$SCRIPT_DIR/metrics/network.sh"
source "$SCRIPT_DIR/metrics/shares_ini.sh"
source "$SCRIPT_DIR/metrics/system.sh"

trap 'on_exit $?' EXIT

# =============================================================================
# MAIN LOOP
# =============================================================================

main() {
  log "unraid-stats2mqtt starting (PID $$)"
  echo $$ > "$PID_FILE"

  load_config
  if [ "$PLUGIN_ENABLED" != "true" ]; then log "Plugin disabled. Exiting."; exit 0; fi

  mqtt_publish "$AVAILABILITY_TOPIC" "online" true
  sleep 1

  local HA_ONLINE_FLAG="$STATE_DIR/ha_came_online"
  rm -f "$HA_ONLINE_FLAG"
  HA_SUB_PID=""
  if [ "$HA_WATCH_STATUS" = "true" ]; then
    build_mqtt_args
    mosquitto_sub "${MQTT_ARGS[@]}" -t "$HA_STATUS_TOPIC" 2>>"$LOG_FILE" | while read -r msg; do
      [ "$msg" = "online" ] && log "HA came online — re-publishing discovery" && touch "$HA_ONLINE_FLAG"
    done &
    HA_SUB_PID=$!
  fi

  trap '_CLEAN_EXIT=1; mqtt_publish "$AVAILABILITY_TOPIC" "offline" true; [ -n "$HA_SUB_PID" ] && kill "$HA_SUB_PID" 2>/dev/null; exit' EXIT INT TERM

  local TICK=0

  while true; do
    load_config

    # ── var.ini: Array Status ──────────────────────────────────────────────────
    local arr_mode="${PUBLISH_ARRAY_STATUS:-}"
    local arr_interval="${INTERVAL_ARRAY_STATUS:-30}"
    local arr_expire; arr_expire=$(resolve_expire "${EXPIRE_ARRAY_STATUS:-0}" "$arr_interval")
    local arr_retain="${RETAIN_ARRAY_STATUS:-true}"
    if is_enabled "$arr_mode"; then
      local arr_status; arr_status=$(get_array_status)
      local _arr_published=0
      if [[ "$arr_mode" == "onchange" || "$arr_mode" == "both" ]]; then
        state_changed "array_status" "$arr_status" && { log "State change publish: array_status"; publish_array_status "$arr_expire" "$arr_retain"; _arr_published=1; }
      fi
      if [[ "$arr_mode" == "interval" || "$arr_mode" == "both" ]]; then
        [[ "$_arr_published" -eq 0 ]] && should_publish_interval "array_status_interval" "$arr_interval" "$TICK" && { log "Interval publish: array_status"; publish_array_status "$arr_expire" "$arr_retain"; }
      fi
    fi

    # ── var.ini: Array Summary (disk counts + capacity) ────────────────────────
    local arr_sum_mode="${PUBLISH_ARRAY_SUMMARY:-}"
    local arr_sum_interval="${INTERVAL_ARRAY_SUMMARY:-60}"
    local arr_sum_expire; arr_sum_expire=$(resolve_expire "${EXPIRE_ARRAY_SUMMARY:-0}" "$arr_sum_interval")
    local arr_sum_retain="${RETAIN_ARRAY_SUMMARY:-true}"
    _publish_metric "array_summary" "$arr_sum_mode" "$arr_sum_interval" "$arr_sum_expire" publish_array_summary \
      "get_vars_data 2>/dev/null | jq -c '.data.vars | {n:.mdNumDisks,d:.mdNumDisabled,i:.mdNumInvalid,m:.mdNumMissing} // empty'" \
      "$arr_sum_retain"

    # ── var.ini: Cache Pool ────────────────────────────────────────────────────
    local cache_mode="${PUBLISH_CACHE:-}"
    local cache_interval="${INTERVAL_CACHE:-60}"
    local cache_expire; cache_expire=$(resolve_expire "${EXPIRE_CACHE:-0}" "$cache_interval")
    local cache_retain="${RETAIN_CACHE:-true}"
    _publish_metric "cache" "$cache_mode" "$cache_interval" "$cache_expire" publish_cache \
      "get_array_data 2>/dev/null | jq -c '.data.array.caches // empty'" \
      "$cache_retain"

    # ── var.ini: Parity ────────────────────────────────────────────────────────
    local par_mode="${PUBLISH_PARITY:-}"
    local par_interval="${INTERVAL_PARITY:-60}"
    local par_expire; par_expire=$(resolve_expire "${EXPIRE_PARITY:-0}" "$par_interval")
    local par_retain="${RETAIN_PARITY:-true}"
    if is_enabled "$par_mode"; then
      local par_info; par_info=$(get_parity_info)
      if [[ "${par_info%%|*}" != "UNKNOWN" ]]; then
        _publish_metric "parity" "$par_mode" "$par_interval" "$par_expire" publish_parity \
          "echo '$par_info'" "$par_retain"
      fi
    fi

    # ── var.ini: Disk Rebuild ──────────────────────────────────────────────────
    local rebuild_mode="${PUBLISH_REBUILD:-}"
    local rebuild_interval="${INTERVAL_REBUILD:-30}"
    local rebuild_expire; rebuild_expire=$(resolve_expire "${EXPIRE_REBUILD:-0}" "$rebuild_interval")
    local rebuild_retain="${RETAIN_REBUILD:-true}"
    if is_enabled "$rebuild_mode"; then
      local rebuild_info; rebuild_info=$(get_rebuild_info)
      if [[ "${rebuild_info%%|*}" != "UNKNOWN" ]]; then
        _publish_metric "rebuild" "$rebuild_mode" "$rebuild_interval" "$rebuild_expire" publish_rebuild \
          "echo '$rebuild_info'" "$rebuild_retain"
      fi
    fi

    # ── var.ini: System Info ───────────────────────────────────────────────────
    local sysinfo_mode="${PUBLISH_SYSTEM_INFO:-}"
    local sysinfo_interval="${INTERVAL_SYSTEM_INFO:-3600}"
    local sysinfo_expire; sysinfo_expire=$(resolve_expire "${EXPIRE_SYSTEM_INFO:-0}" "$sysinfo_interval")
    local sysinfo_retain="${RETAIN_SYSTEM_INFO:-true}"
    _publish_metric "system_info" "$sysinfo_mode" "$sysinfo_interval" "$sysinfo_expire" publish_system_info \
      "get_vars_data 2>/dev/null | jq -r '.data.vars.version // empty'" "$sysinfo_retain"

    # ── var.ini: Update Available ──────────────────────────────────────────────
    local update_mode="${PUBLISH_UPDATE_AVAILABLE:-}"
    local update_interval="${INTERVAL_UPDATE_AVAILABLE:-3600}"
    local update_expire; update_expire=$(resolve_expire "${EXPIRE_UPDATE_AVAILABLE:-0}" "$update_interval")
    local update_retain="${RETAIN_UPDATE_AVAILABLE:-true}"
    _publish_metric "update_available" "$update_mode" "$update_interval" "$update_expire" publish_update_available \
      "cat /tmp/unraidcheck/result.json 2>/dev/null | md5sum" "$update_retain"

    # ── disks.ini: Disk Temperatures ──────────────────────────────────────────
    local temp_mode="${PUBLISH_DISK_TEMPS:-}"
    local temp_interval="${INTERVAL_DISK_TEMPS:-60}"
    local temp_expire; temp_expire=$(resolve_expire "${EXPIRE_DISK_TEMPS:-0}" "$temp_interval")
    local temp_retain="${RETAIN_DISK_TEMPS:-true}"
    _publish_metric "disk_temps" "$temp_mode" "$temp_interval" "$temp_expire" publish_disk_temps \
      "get_array_data 2>/dev/null | jq -c '[(.data.array.disks[],.data.array.parities[]) | .temp] // empty'" "$temp_retain"

    # ── disks.ini: Disk States ─────────────────────────────────────────────────
    local ds_mode="${PUBLISH_DISK_STATES:-}"
    local ds_interval="${INTERVAL_DISK_STATES:-30}"
    local ds_expire; ds_expire=$(resolve_expire "${EXPIRE_DISK_STATES:-0}" "$ds_interval")
    local ds_retain="${RETAIN_DISK_STATES:-true}"
    _publish_metric "disk_states" "$ds_mode" "$ds_interval" "$ds_expire" publish_disk_states \
      "get_array_data 2>/dev/null | jq -c '[.data.array.disks[] | {s:.status,p:.isSpinning}] // empty'" "$ds_retain"

    # ── disks.ini: Disk Filesystem Usage ──────────────────────────────────────
    local disk_usage_mode="${PUBLISH_DISK_USAGE:-}"
    local disk_usage_interval="${INTERVAL_DISK_USAGE:-300}"
    local disk_usage_expire; disk_usage_expire=$(resolve_expire "${EXPIRE_DISK_USAGE:-0}" "$disk_usage_interval")
    local disk_usage_retain="${RETAIN_DISK_USAGE:-true}"
    _publish_metric "disk_usage" "$disk_usage_mode" "$disk_usage_interval" "$disk_usage_expire" publish_disk_usage \
      "get_array_data 2>/dev/null | jq -c '[.data.array.disks[] | {s:.fsSize,f:.fsFree}] // empty'" "$disk_usage_retain"

    # ── disks.ini: Disk Errors & Health Color ─────────────────────────────────
    local disk_errors_mode="${PUBLISH_DISK_ERRORS:-}"
    local disk_errors_interval="${INTERVAL_DISK_ERRORS:-300}"
    local disk_errors_expire; disk_errors_expire=$(resolve_expire "${EXPIRE_DISK_ERRORS:-0}" "$disk_errors_interval")
    local disk_errors_retain="${RETAIN_DISK_ERRORS:-true}"
    _publish_metric "disk_errors" "$disk_errors_mode" "$disk_errors_interval" "$disk_errors_expire" publish_disk_errors \
      "awk '/^(numErrors|color)=/{print}' /var/local/emhttp/disks.ini 2>/dev/null | md5sum" "$disk_errors_retain"

    # ── disks.ini + smartctl: SMART ────────────────────────────────────────────
    local smart_mode="${PUBLISH_SMART:-}"
    local smart_interval="${INTERVAL_SMART:-300}"
    local smart_expire; smart_expire=$(resolve_expire "${EXPIRE_SMART:-0}" "$smart_interval")
    local smart_retain="${RETAIN_SMART:-true}"
    if [[ "$smart_mode" == "interval" || "$smart_mode" == "both" ]]; then
      should_publish_interval "smart_interval" "$smart_interval" "$TICK" && { log "Interval publish: smart"; publish_smart "$smart_expire" "$smart_retain"; }
    fi

    # ── disks.ini + /proc/diskstats: R/W Speeds ────────────────────────────────
    local rw_mode="${PUBLISH_RW_SPEEDS:-}"
    local rw_interval="${INTERVAL_RW_SPEEDS:-30}"
    local rw_expire; rw_expire=$(resolve_expire "${EXPIRE_RW_SPEEDS:-0}" "$rw_interval")
    if [[ "$rw_mode" == "interval" || "$rw_mode" == "both" ]]; then
      should_publish_interval "rw_speeds_interval" "$rw_interval" "$TICK" && { log "Interval publish: rw_speeds"; publish_rw_speeds "$rw_expire"; }
    fi
    [[ "$rw_mode" == "onchange" ]] && publish_rw_speeds "$rw_expire"

    # ── monitor.ini ───────────────────────────────────────────────────────────
    local monitor_mode="${PUBLISH_MONITOR:-}"
    local monitor_interval="${INTERVAL_MONITOR:-60}"
    local monitor_expire; monitor_expire=$(resolve_expire "${EXPIRE_MONITOR:-0}" "$monitor_interval")
    local monitor_retain="${RETAIN_MONITOR:-true}"
    _publish_metric "monitor" "$monitor_mode" "$monitor_interval" "$monitor_expire" publish_monitor \
      "md5sum /var/local/emhttp/monitor.ini 2>/dev/null" "$monitor_retain"

    # ── /proc/net/dev: Network Speeds ─────────────────────────────────────────
    local net_mode="${PUBLISH_NETWORK:-}"
    local net_interval="${INTERVAL_NETWORK:-30}"
    local net_expire; net_expire=$(resolve_expire "${EXPIRE_NETWORK:-0}" "$net_interval")
    local net_retain="${RETAIN_NETWORK:-true}"
    if [[ "$net_mode" == "interval" || "$net_mode" == "both" ]]; then
      should_publish_interval "network_interval" "$net_interval" "$TICK" && { log "Interval publish: network"; publish_network_speeds "$net_expire" "$net_retain"; }
    fi
    [[ "$net_mode" == "onchange" ]] && publish_network_speeds "$net_expire" "$net_retain"

    # ── /proc/uptime: System Uptime ───────────────────────────────────────────
    local uptime_mode="${PUBLISH_UPTIME:-}"
    local uptime_interval="${INTERVAL_UPTIME:-60}"
    local uptime_expire; uptime_expire=$(resolve_expire "${EXPIRE_UPTIME:-0}" "$uptime_interval")
    local uptime_retain="${RETAIN_UPTIME:-true}"
    _publish_metric "uptime" "$uptime_mode" "$uptime_interval" "$uptime_expire" publish_uptime \
      "awk '{printf \"%d\", $1/60}' /proc/uptime 2>/dev/null" "$uptime_retain"

    # ── shares.ini ────────────────────────────────────────────────────────────
    local shares_mode="${PUBLISH_SHARES:-}"
    local shares_interval="${INTERVAL_SHARES:-300}"
    local shares_expire; shares_expire=$(resolve_expire "${EXPIRE_SHARES:-0}" "$shares_interval")
    local shares_retain="${RETAIN_SHARES:-true}"
    _publish_metric "shares" "$shares_mode" "$shares_interval" "$shares_expire" publish_shares \
      "md5sum /var/local/emhttp/shares.ini 2>/dev/null" "$shares_retain"

    # ── Re-publish everything when HA restarts ─────────────────────────────────
    if [ -f "$HA_ONLINE_FLAG" ]; then
      rm -f "$HA_ONLINE_FLAG"
      _HA_REGISTERED=()
      mqtt_publish "$AVAILABILITY_TOPIC" "online" true
      is_enabled "$arr_mode"          && publish_array_status  "$arr_expire"      "$arr_retain"
      is_enabled "$arr_sum_mode"      && publish_array_summary "$arr_sum_expire"  "$arr_sum_retain"
      is_enabled "$cache_mode"        && publish_cache         "$cache_expire"    "$cache_retain"
      is_enabled "$par_mode"          && publish_parity        "$par_expire"      "$par_retain"
      is_enabled "$rebuild_mode"      && publish_rebuild       "$rebuild_expire"  "$rebuild_retain"
      is_enabled "$sysinfo_mode"      && publish_system_info   "$sysinfo_expire"  "$sysinfo_retain"
      is_enabled "$update_mode"       && publish_update_available "$update_expire" "$update_retain"
      is_enabled "$temp_mode"         && publish_disk_temps    "$temp_expire"     "$temp_retain"
      is_enabled "$ds_mode"           && publish_disk_states   "$ds_expire"       "$ds_retain"
      is_enabled "$disk_usage_mode"   && publish_disk_usage    "$disk_usage_expire" "$disk_usage_retain"
      is_enabled "$disk_errors_mode"  && publish_disk_errors   "$disk_errors_expire" "$disk_errors_retain"
      is_enabled "$smart_mode"        && publish_smart         "$smart_expire"    "$smart_retain"
      is_enabled "$rw_mode"           && publish_rw_speeds     "$rw_expire"
      is_enabled "$monitor_mode"      && publish_monitor       "$monitor_expire"  "$monitor_retain"
      is_enabled "$net_mode"          && publish_network_speeds "$net_expire"     "$net_retain"
      is_enabled "$shares_mode"       && publish_shares        "$shares_expire"   "$shares_retain"
      is_enabled "$uptime_mode"       && publish_uptime        "$uptime_expire"   "$uptime_retain"
    fi

    # Heartbeat: keep HA from marking device unavailable
    should_publish_interval "availability_heartbeat" 60 "$TICK" && mqtt_publish "$AVAILABILITY_TOPIC" "online" true

    TICK=$(( TICK + 10 ))
    sleep 10
  done
}


# =============================================================================
# ENTRY POINT
# =============================================================================

case "${1:-}" in
  test)
    load_config
    test_topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_test/state"
    test_payload="unraid-stats2mqtt test OK $(date)"
    log "Test publish requested via UI"
    if mqtt_publish "$test_topic" "$test_payload"; then
      log "Test publish succeeded: ${MQTT_PROTOCOL}://${MQTT_HOST}:${MQTT_PORT} → ${test_topic}"
      echo "Published to ${MQTT_PROTOCOL}://${MQTT_HOST}:${MQTT_PORT}"
      echo "  Topic:   ${test_topic}"
      echo "  Payload: ${test_payload}"
    else
      log "Test publish failed: ${MQTT_PROTOCOL}://${MQTT_HOST}:${MQTT_PORT} → ${test_topic}"
      echo "Test failed: could not connect to ${MQTT_PROTOCOL}://${MQTT_HOST}:${MQTT_PORT}" >&2
      exit 1
    fi
    ;;
  check_connection)
    load_config
    log "Connection test requested via UI: ${MQTT_PROTOCOL}://${MQTT_HOST}:${MQTT_PORT}"
    build_mqtt_args
    if mosquitto_pub "${MQTT_ARGS[@]}" -k 5 -t "unraid-stats2mqtt/connection_test" -m "ping" 2>&1; then
      log "Connection test succeeded: ${MQTT_PROTOCOL}://${MQTT_HOST}:${MQTT_PORT}"
      echo "Connection successful: ${MQTT_PROTOCOL}://${MQTT_HOST}:${MQTT_PORT}"
    else
      log "Connection test failed: ${MQTT_PROTOCOL}://${MQTT_HOST}:${MQTT_PORT}"
      echo "Connection failed: ${MQTT_PROTOCOL}://${MQTT_HOST}:${MQTT_PORT}" >&2
      exit 1
    fi
    ;;
  *)
    main
    ;;
esac

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
source "$SCRIPT_DIR/collectors/unraid-api.sh"
source "$SCRIPT_DIR/publishers/unraid-api/var.sh"
source "$SCRIPT_DIR/publishers/unraid-api/shares.sh"
source "$SCRIPT_DIR/publishers/unraid-api/monitor.sh"
source "$SCRIPT_DIR/publishers/unraid-api/system.sh"
source "$SCRIPT_DIR/publishers/ini/disks_ini.sh"

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

    local arr_interval="${INTERVAL_ARRAY_STATUS:-30}"
    local arr_expire; arr_expire=$(resolve_expire "${EXPIRE_ARRAY_STATUS:-0}" "$arr_interval")
    local arr_retain="${RETAIN_ARRAY_STATUS:-true}"
    _publish_metric "array_status"   "$arr_interval"  "$arr_expire"  publish_array_status  "$arr_retain"

    local arr_sum_interval="${INTERVAL_ARRAY_SUMMARY:-60}"
    local arr_sum_expire; arr_sum_expire=$(resolve_expire "${EXPIRE_ARRAY_SUMMARY:-0}" "$arr_sum_interval")
    local arr_sum_retain="${RETAIN_ARRAY_SUMMARY:-true}"
    _publish_metric "array_summary"  "$arr_sum_interval" "$arr_sum_expire" publish_array_summary "$arr_sum_retain"

    local cache_interval="${INTERVAL_CACHE:-60}"
    local cache_expire; cache_expire=$(resolve_expire "${EXPIRE_CACHE:-0}" "$cache_interval")
    local cache_retain="${RETAIN_CACHE:-true}"
    _publish_metric "cache"          "$cache_interval" "$cache_expire" publish_cache         "$cache_retain"

    local par_interval="${INTERVAL_PARITY:-60}"
    local par_expire; par_expire=$(resolve_expire "${EXPIRE_PARITY:-0}" "$par_interval")
    local par_retain="${RETAIN_PARITY:-true}"
    _publish_metric "parity"         "$par_interval"  "$par_expire"  publish_parity         "$par_retain"

    local rebuild_interval="${INTERVAL_REBUILD:-30}"
    local rebuild_expire; rebuild_expire=$(resolve_expire "${EXPIRE_REBUILD:-0}" "$rebuild_interval")
    local rebuild_retain="${RETAIN_REBUILD:-true}"
    _publish_metric "rebuild"        "$rebuild_interval" "$rebuild_expire" publish_rebuild   "$rebuild_retain"

    local sysinfo_interval="${INTERVAL_SYSTEM_INFO:-3600}"
    local sysinfo_expire; sysinfo_expire=$(resolve_expire "${EXPIRE_SYSTEM_INFO:-0}" "$sysinfo_interval")
    local sysinfo_retain="${RETAIN_SYSTEM_INFO:-true}"
    _publish_metric "system_info"    "$sysinfo_interval" "$sysinfo_expire" publish_system_info "$sysinfo_retain"

    local update_interval="${INTERVAL_UPDATE_AVAILABLE:-3600}"
    local update_expire; update_expire=$(resolve_expire "${EXPIRE_UPDATE_AVAILABLE:-0}" "$update_interval")
    local update_retain="${RETAIN_UPDATE_AVAILABLE:-true}"
    _publish_metric "update_available" "$update_interval" "$update_expire" publish_update_available "$update_retain"

    local temp_interval="${INTERVAL_DISK_TEMPS:-60}"
    local temp_expire; temp_expire=$(resolve_expire "${EXPIRE_DISK_TEMPS:-0}" "$temp_interval")
    local temp_retain="${RETAIN_DISK_TEMPS:-true}"
    _publish_metric "disk_temps"     "$temp_interval"  "$temp_expire"  publish_disk_temps    "$temp_retain"

    local ds_interval="${INTERVAL_DISK_STATES:-30}"
    local ds_expire; ds_expire=$(resolve_expire "${EXPIRE_DISK_STATES:-0}" "$ds_interval")
    local ds_retain="${RETAIN_DISK_STATES:-true}"
    _publish_metric "disk_states"    "$ds_interval"   "$ds_expire"   publish_disk_states    "$ds_retain"

    local disk_usage_interval="${INTERVAL_DISK_USAGE:-300}"
    local disk_usage_expire; disk_usage_expire=$(resolve_expire "${EXPIRE_DISK_USAGE:-0}" "$disk_usage_interval")
    local disk_usage_retain="${RETAIN_DISK_USAGE:-true}"
    _publish_metric "disk_usage"     "$disk_usage_interval" "$disk_usage_expire" publish_disk_usage "$disk_usage_retain"

    local disk_errors_interval="${INTERVAL_DISK_ERRORS:-300}"
    local disk_errors_expire; disk_errors_expire=$(resolve_expire "${EXPIRE_DISK_ERRORS:-0}" "$disk_errors_interval")
    local disk_errors_retain="${RETAIN_DISK_ERRORS:-true}"
    _publish_metric "disk_errors"    "$disk_errors_interval" "$disk_errors_expire" publish_disk_errors "$disk_errors_retain"

    local rw_interval="${INTERVAL_RW_SPEEDS:-30}"
    local rw_expire; rw_expire=$(resolve_expire "${EXPIRE_RW_SPEEDS:-0}" "$rw_interval")
    _publish_metric "rw_speeds"      "$rw_interval"   "$rw_expire"   publish_rw_speeds

    local monitor_interval="${INTERVAL_MONITOR:-60}"
    local monitor_expire; monitor_expire=$(resolve_expire "${EXPIRE_MONITOR:-0}" "$monitor_interval")
    local monitor_retain="${RETAIN_MONITOR:-true}"
    _publish_metric "monitor"        "$monitor_interval" "$monitor_expire" publish_monitor   "$monitor_retain"

    local uptime_interval="${INTERVAL_UPTIME:-60}"
    local uptime_expire; uptime_expire=$(resolve_expire "${EXPIRE_UPTIME:-0}" "$uptime_interval")
    local uptime_retain="${RETAIN_UPTIME:-true}"
    _publish_metric "uptime"         "$uptime_interval" "$uptime_expire" publish_uptime      "$uptime_retain"

    local shares_interval="${INTERVAL_SHARES:-300}"
    local shares_expire; shares_expire=$(resolve_expire "${EXPIRE_SHARES:-0}" "$shares_interval")
    local shares_retain="${RETAIN_SHARES:-true}"
    _publish_metric "shares"         "$shares_interval" "$shares_expire" publish_shares      "$shares_retain"

    # ── Re-publish everything when HA restarts ─────────────────────────────────
    if [ -f "$HA_ONLINE_FLAG" ]; then
      rm -f "$HA_ONLINE_FLAG"
      _HA_REGISTERED=()
      mqtt_publish "$AVAILABILITY_TOPIC" "online" true
      [ "${arr_interval:-0}"          -gt 0 ] && publish_array_status    "$arr_expire"          "$arr_retain"
      [ "${arr_sum_interval:-0}"      -gt 0 ] && publish_array_summary   "$arr_sum_expire"      "$arr_sum_retain"
      [ "${cache_interval:-0}"        -gt 0 ] && publish_cache           "$cache_expire"        "$cache_retain"
      [ "${par_interval:-0}"          -gt 0 ] && publish_parity          "$par_expire"          "$par_retain"
      [ "${rebuild_interval:-0}"      -gt 0 ] && publish_rebuild         "$rebuild_expire"      "$rebuild_retain"
      [ "${sysinfo_interval:-0}"      -gt 0 ] && publish_system_info     "$sysinfo_expire"      "$sysinfo_retain"
      [ "${update_interval:-0}"       -gt 0 ] && publish_update_available "$update_expire"      "$update_retain"
      [ "${temp_interval:-0}"         -gt 0 ] && publish_disk_temps      "$temp_expire"         "$temp_retain"
      [ "${ds_interval:-0}"           -gt 0 ] && publish_disk_states     "$ds_expire"           "$ds_retain"
      [ "${disk_usage_interval:-0}"   -gt 0 ] && publish_disk_usage      "$disk_usage_expire"   "$disk_usage_retain"
      [ "${disk_errors_interval:-0}"  -gt 0 ] && publish_disk_errors     "$disk_errors_expire"  "$disk_errors_retain"
      [ "${rw_interval:-0}"           -gt 0 ] && publish_rw_speeds       "$rw_expire"
      [ "${monitor_interval:-0}"      -gt 0 ] && publish_monitor         "$monitor_expire"      "$monitor_retain"
      [ "${net_interval:-0}"          -gt 0 ] && publish_network         "$net_expire"          "$net_retain"
      [ "${shares_interval:-0}"       -gt 0 ] && publish_shares          "$shares_expire"       "$shares_retain"
      [ "${uptime_interval:-0}"       -gt 0 ] && publish_uptime          "$uptime_expire"       "$uptime_retain"
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

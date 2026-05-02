#!/bin/bash

publish_uptime() {
  local expire="${1:-0}" retain="${2:-true}"
  local info; info=$(get_info_data) || return
  local uptime_raw; uptime_raw=$(echo "$info" | jq -r '.data.info.os.uptime // empty')
  [ -z "$uptime_raw" ] && return
  local uptime_seconds boot_epoch now_epoch
  if [[ "$uptime_raw" =~ ^[0-9]+$ ]]; then
    uptime_seconds="$uptime_raw"
  else
    local uptime_clean="${uptime_raw%.*}"
    boot_epoch=$(date -d "$uptime_clean" +%s 2>/dev/null) || return
    now_epoch=$(date +%s)
    uptime_seconds=$(( now_epoch - boot_epoch ))
  fi
  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"
  ha_register "system_uptime" "System Uptime" "${base}_system_uptime/state" "s" "duration" "timer-outline" "" "$expire"
  mqtt_publish "${base}_system_uptime/state" "$uptime_seconds" "$retain"
}

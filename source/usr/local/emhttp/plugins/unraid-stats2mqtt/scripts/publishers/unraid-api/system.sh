#!/bin/bash

publish_uptime() {
  local expire="${1:-0}" retain="${2:-true}"
  local info; info=$(get_info_data) || return
  local uptime_seconds; uptime_seconds=$(echo "$info" | jq -r '.data.info.os.uptime // empty')
  [ -z "$uptime_seconds" ] && return
  local days=$(( uptime_seconds / 86400 ))
  local hours=$(( (uptime_seconds % 86400) / 3600 ))
  local minutes=$(( (uptime_seconds % 3600) / 60 ))
  local secs=$(( uptime_seconds % 60 ))
  local uptime_fmt; printf -v uptime_fmt "%d %02d:%02d:%02d" "$days" "$hours" "$minutes" "$secs"
  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"
  ha_register "system_uptime" "System Uptime" "${base}_system_uptime/state" "s" "duration" "timer-outline" "" "$expire"
  mqtt_publish "${base}_system_uptime/state" "$uptime_fmt" "$retain"
}

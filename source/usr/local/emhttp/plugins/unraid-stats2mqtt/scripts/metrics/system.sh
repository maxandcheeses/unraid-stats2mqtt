#!/bin/bash
# SOURCE: /proc/uptime
# Fields: system uptime in seconds

publish_uptime() {
  local expire="${1:-0}" retain="${2:-true}"
  local uptime_seconds
  uptime_seconds=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
  [ -z "$uptime_seconds" ] && return
  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"
  ha_register "system_uptime" "System Uptime" "${base}_system_uptime/state" "s" "duration" "timer-outline" "" "$expire"
  mqtt_publish "${base}_system_uptime/state" "$uptime_seconds" "$retain"
}

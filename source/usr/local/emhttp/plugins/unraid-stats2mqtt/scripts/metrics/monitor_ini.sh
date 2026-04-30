#!/bin/bash
# SOURCE: monitor.ini
# Sections and fields:
#   [array]  errors           → cumulative array error count
#   [parity] parity           → last parity operation status string
#   [flash]  flash            → boot flash mount state (rw / ro)
#   [system] docker           → Docker vdisk utilization %
#   [used]   {diskname}       → per-disk filesystem usage %
#   [disk]   {diskname}       → per-disk alert color (green/yellow/red)

publish_monitor() {
  local expire="${1:-0}" retain="${2:-true}"
  local mon_file="/var/local/emhttp/monitor.ini"
  [ ! -f "$mon_file" ] && return
  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"

  local arr_errors
  arr_errors=$(ini_field "$(read_ini_section "$mon_file" "array")" errors)
  [ -n "$arr_errors" ] && {
    ha_register "monitor_array_errors" "Array Errors" \
      "${base}_monitor_array_errors/state" "" "" "alert" "" "$expire"
    mqtt_publish "${base}_monitor_array_errors/state" "$arr_errors" "$retain"
  }

  local parity_hist
  parity_hist=$(ini_field "$(read_ini_section "$mon_file" "parity")" parity)
  [ -n "$parity_hist" ] && {
    ha_register "monitor_parity_history" "Parity History" \
      "${base}_monitor_parity_history/state" "" "" "shield-check" "" "$expire"
    mqtt_publish "${base}_monitor_parity_history/state" "$parity_hist" "$retain"
  }

  local flash_state
  flash_state=$(ini_field "$(read_ini_section "$mon_file" "flash")" flash)
  [ -n "$flash_state" ] && {
    ha_register "flash_state" "Flash Drive State" \
      "${base}_flash_state/state" "" "" "usb-flash-drive" "" "$expire"
    mqtt_publish "${base}_flash_state/state" "$flash_state" "$retain"
  }

  local docker_usage
  docker_usage=$(ini_field "$(read_ini_section "$mon_file" "system")" docker)
  [ -n "$docker_usage" ] && {
    ha_register "docker_disk_usage" "Docker Disk Usage" \
      "${base}_docker_disk_usage/state" "%" "" "docker" "" "$expire"
    mqtt_publish "${base}_docker_disk_usage/state" "$docker_usage" "$retain"
  }

  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    val="${val//\"/}"
    local sn; sn=$(safe_name "$key")
    ha_register "monitor_${sn}_used_pct" "${key} Usage" \
      "${base}_monitor_${sn}_used_pct/state" "%" "" "gauge" "" "$expire"
    mqtt_publish "${base}_monitor_${sn}_used_pct/state" "$val" "$retain"
  done < <(read_ini_section "$mon_file" "used")

  while IFS='=' read -r key val; do
    [ -z "$key" ] && continue
    val="${val//\"/}"
    local sn; sn=$(safe_name "$key")
    ha_register "monitor_${sn}_alert" "${key} Alert" \
      "${base}_monitor_${sn}_alert/state" "" "" "palette" "" "$expire"
    mqtt_publish "${base}_monitor_${sn}_alert/state" "$val" "$retain"
  done < <(read_ini_section "$mon_file" "disk")
}

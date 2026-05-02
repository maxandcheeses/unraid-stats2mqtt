#!/bin/bash

publish_array_status() {
  local expire="${1:-0}" retain="${2:-true}"
  local status; status=$(get_array_status)
  [ "$status" = "UNKNOWN" ] && return
  local topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_array_status/state"
  ha_register "array_status" "Array Status" "$topic" "" "" "harddisk" "" "$expire"
  mqtt_publish "$topic" "$status" "$retain"
}

publish_array_summary() {
  local expire="${1:-0}" retain="${2:-true}"
  local arr;  arr=$(get_array_data)  || return
  local vars; vars=$(get_vars_data)  || return
  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"

  local num_disks num_disabled num_invalid num_missing
  num_disks=$(echo    "$vars" | jq -r '.data.vars.mdNumDisks    // empty')
  num_disabled=$(echo "$vars" | jq -r '.data.vars.mdNumDisabled // empty')
  num_invalid=$(echo  "$vars" | jq -r '.data.vars.mdNumInvalid  // empty')
  num_missing=$(echo  "$vars" | jq -r '.data.vars.mdNumMissing  // empty')

  [ -n "$num_disks" ] && {
    ha_register "array_num_disks" "Array Disk Count" "${base}_array_num_disks/state" "" "" "harddisk" "" "$expire"
    mqtt_publish "${base}_array_num_disks/state" "$num_disks" "$retain"
  }
  [ -n "$num_disabled" ] && {
    ha_register "array_disabled_disks" "Array Disabled Disks" "${base}_array_disabled_disks/state" "" "" "harddisk-remove" "" "$expire"
    mqtt_publish "${base}_array_disabled_disks/state" "$num_disabled" "$retain"
  }
  [ -n "$num_invalid" ] && {
    ha_register "array_invalid_disks" "Array Invalid Disks" "${base}_array_invalid_disks/state" "" "" "alert-circle-outline" "" "$expire"
    mqtt_publish "${base}_array_invalid_disks/state" "$num_invalid" "$retain"
  }
  [ -n "$num_missing" ] && {
    ha_register "array_missing_disks" "Array Missing Disks" "${base}_array_missing_disks/state" "" "" "harddisk-remove" "" "$expire"
    mqtt_publish "${base}_array_missing_disks/state" "$num_missing" "$retain"
  }

  local total free used
  total=$(echo "$arr" | jq -r '.data.array.capacity.kilobytes.total // empty')
  free=$(echo  "$arr" | jq -r '.data.array.capacity.kilobytes.free  // empty')
  used=$(echo  "$arr" | jq -r '.data.array.capacity.kilobytes.used  // empty')

  if [ "${total:-0}" -gt 0 ] 2>/dev/null; then
    local cap_gb; cap_gb=$(awk "BEGIN{printf \"%.2f\", $total/1048576}")
    ha_register "array_capacity" "Array Capacity" "${base}_array_capacity/state" "GB" "data_size" "harddisk" "" "$expire"
    mqtt_publish "${base}_array_capacity/state" "$cap_gb" "$retain"

    if [ "${used:-0}" -gt 0 ] 2>/dev/null; then
      local used_gb; used_gb=$(awk "BEGIN{printf \"%.2f\", $used/1048576}")
      ha_unregister "array_free"
      ha_register "array_used" "Array Used" "${base}_array_used/state" "GB" "data_size" "harddisk" "" "$expire"
      mqtt_publish "${base}_array_used/state" "$used_gb" "$retain"
    fi
  fi
}

publish_cache() {
  local expire="${1:-0}" retain="${2:-true}"
  local arr; arr=$(get_array_data) || return
  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"

  local cache_count; cache_count=$(echo "$arr" | jq '.data.array.caches | length')
  [ "${cache_count:-0}" -eq 0 ] && return

  local total_size=0 total_free=0 total_used=0 all_ok=true

  while IFS=$'\t' read -r status fs_size fs_free fs_used; do
    [ "$status" != "DISK_OK" ] && all_ok=false
    [ "${fs_size:-0}" -gt 0 ] 2>/dev/null && {
      total_size=$(( total_size + fs_size ))
      total_free=$(( total_free + ${fs_free:-0} ))
      total_used=$(( total_used + ${fs_used:-0} ))
    }
  done < <(echo "$arr" | jq -r '.data.array.caches[] | [.status // "", (.fsSize // 0), (.fsFree // 0), (.fsUsed // 0)] | @tsv')

  local cache_state="ACTIVE"; [ "$all_ok" = "false" ] && cache_state="DEGRADED"

  ha_register "cache_state" "Cache State" "${base}_cache_state/state" "" "" "lightning-bolt" "" "$expire"
  mqtt_publish "${base}_cache_state/state" "$cache_state" "$retain"

  ha_register "cache_num_devices" "Cache Devices" "${base}_cache_num_devices/state" "" "" "lightning-bolt" "" "$expire"
  mqtt_publish "${base}_cache_num_devices/state" "$cache_count" "$retain"

  if [ "$total_size" -gt 0 ] 2>/dev/null; then
    local size_gb; size_gb=$(awk "BEGIN{printf \"%.2f\", $total_size/1048576}")
    ha_register "cache_capacity" "Cache Capacity" "${base}_cache_capacity/state" "GB" "data_size" "lightning-bolt" "" "$expire"
    mqtt_publish "${base}_cache_capacity/state" "$size_gb" "$retain"

    ha_unregister "cache_free"

    local used_kb="$total_used"
    [ "${used_kb:-0}" -le 0 ] 2>/dev/null && [ "$total_free" -gt 0 ] 2>/dev/null && \
      used_kb=$(( total_size - total_free ))
    [ "${used_kb:-0}" -gt 0 ] 2>/dev/null && {
      local used_gb; used_gb=$(awk "BEGIN{printf \"%.2f\", $used_kb/1048576}")
      ha_register "cache_used" "Cache Used" "${base}_cache_used/state" "GB" "data_size" "lightning-bolt" "" "$expire"
      mqtt_publish "${base}_cache_used/state" "$used_gb" "$retain"
    }
  fi
}

publish_parity() {
  local expire="${1:-0}" retain="${2:-true}"
  local info; info=$(get_parity_info)
  local parity_state parity_pct parity_speed
  IFS='|' read -r parity_state parity_pct parity_speed <<< "$info"
  [ "$parity_state" = "UNKNOWN" ] && return

  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_parity"
  ha_register "parity_status"   "Parity Status"   "${base}_status/state"   ""  "" "shield-check"   "" "$expire"
  ha_register "parity_progress" "Parity Progress" "${base}_progress/state" "%" "" "progress-check" "" "$expire"
  ha_register "parity_speed"    "Parity Speed"    "${base}_speed/state"    ""  "" "speedometer"    "" "$expire"
  mqtt_publish "${base}_status/state"   "$parity_state"  "$retain"
  mqtt_publish "${base}_progress/state" "$parity_pct"    "$retain"
  mqtt_publish "${base}_speed/state"    "$parity_speed"  "$retain"
}

publish_rebuild() {
  local expire="${1:-0}" retain="${2:-true}"
  local info; info=$(get_rebuild_info)
  local status pct speed eta
  IFS='|' read -r status pct speed eta <<< "$info"
  [ "$status" = "UNKNOWN" ] && return

  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_rebuild"
  ha_register "rebuild_status"   "Rebuild Status"   "${base}_status/state"   ""     "" "harddisk"        "" "$expire"
  ha_register "rebuild_progress" "Rebuild Progress" "${base}_progress/state" "%"    "" "progress-wrench" "" "$expire"
  ha_register "rebuild_speed"    "Rebuild Speed"    "${base}_speed/state"    "KB/s" "" "speedometer"     "" "$expire"
  ha_register "rebuild_eta"      "Rebuild ETA"      "${base}_eta/state"      "min"  "" "timer-outline"   "" "$expire"

  if [ "${pct%.*}" -eq 0 ] 2>/dev/null; then
    sleep 1
    local info2; info2=$(get_rebuild_info)
    [ "${info2%%|*}" = "UNKNOWN" ] && return
    IFS='|' read -r status pct speed eta <<< "$info2"
  fi

  mqtt_publish "${base}_status/state"   "$status" "$retain"
  mqtt_publish "${base}_progress/state" "$pct"    "$retain"
  mqtt_publish "${base}_speed/state"    "$speed"  "$retain"
  mqtt_publish "${base}_eta/state"      "$eta"    "$retain"
}

publish_update_available() {
  local expire="${1:-0}" retain="${2:-true}"
  local state_topic="${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_update_available/state"
  local attr_topic="${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_update_available/attributes"

  ha_register_binary "update_available" "Unraid Update Available" "$state_topic" "update" "package-up" "$expire" "$attr_topic"

  local result; result=$(get_update_check_data)
  if [ $? -ne 0 ]; then
    mqtt_publish "$state_topic" "OFF" "$retain"
    mqtt_publish "$attr_topic" "{}" "$retain"
    return
  fi

  local is_newer; is_newer=$(printf '%s' "$result" | grep -o '"isNewer":[^,}]*' | cut -d: -f2 | tr -d ' "')

  if [ "$is_newer" = "true" ]; then
    mqtt_publish "$state_topic" "ON" "$retain"
  else
    mqtt_publish "$state_topic" "OFF" "$retain"
  fi
  mqtt_publish "$attr_topic" "$result" "$retain"
}

publish_system_info() {
  local expire="${1:-0}" retain="${2:-true}"
  local vars; vars=$(get_vars_data) || return
  local info; info=$(get_info_data) || return

  local version; version=$(echo "$vars" | jq -r '.data.vars.version // empty')
  [ -n "$version" ] && {
    local topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_unraid_version/state"
    ha_register "unraid_version" "Unraid Version" "$topic" "" "" "information-outline" "" "$expire"
    mqtt_publish "$topic" "$version" "$retain"
  }

  local server_name; server_name=$(echo "$vars" | jq -r '.data.vars.name // empty')
  [ -n "$server_name" ] && {
    local state_topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_identification/state"
    local attr_topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_identification/attributes"
    ha_register "identification" "Identification" "$state_topic" "" "" "server" "" "$expire" "$attr_topic"
    mqtt_publish "$state_topic" "$server_name" "$retain"

    local model cpu_brand cpu_cores cpu_threads
    model=$(echo       "$vars" | jq -r '.data.vars.sysModel    // empty')
    cpu_brand=$(echo   "$info" | jq -r '.data.info.cpu.brand   // empty')
    cpu_cores=$(echo   "$info" | jq -r '.data.info.cpu.cores   // 0')
    cpu_threads=$(echo "$info" | jq -r '.data.info.cpu.threads // 0')

    local attrs
    attrs=$(printf '{"name":"%s","sysModel":"%s","version":"%s","brand":"%s","cores":%s,"threads":%s}' \
      "$(json_escape "$server_name")" "$(json_escape "$model")" "$(json_escape "${version:-}")" \
      "$(json_escape "$cpu_brand")" "${cpu_cores:-0}" "${cpu_threads:-0}")
    mqtt_publish "$attr_topic" "$attrs" "$retain"
  }
}

#!/bin/bash
# SOURCE: var.ini, /tmp/unraidcheck/result.json
# Fields: mdState, mdNumDisks, mdNumDisabled, mdNumInvalid, mdNumMissing,
#         mdCapacity, mdFree, mdResync*, cacheState, cacheNumDevices,
#         cacheFsSize, cacheFsFree, cacheFsUsed, version

read_var_ini() { cat /var/local/emhttp/var.ini 2>/dev/null; }
var_field()    { ini_field "$1" "$2"; }

get_array_status() {
  local md_state
  md_state=$(grep -m1 '^mdState=' /var/local/emhttp/var.ini 2>/dev/null | cut -d'"' -f2)
  case "$md_state" in
    STARTED)   echo "STARTED" ;;
    STOPPED)   echo "STOPPED" ;;
    NEW_ARRAY) echo "STOPPED" ;;
    ERROR)     echo "DEGRADED" ;;
    *)
      if cat /proc/mdstat 2>/dev/null | grep -q "\[.*_.*\]"; then
        echo "DEGRADED"
      elif [ -n "$md_state" ]; then
        echo "$md_state"
      else
        echo "STOPPED"
      fi
      ;;
  esac
}

publish_array_status() {
  local expire="${1:-0}" retain="${2:-true}"
  local status; status=$(get_array_status)
  local topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_array_status/state"
  ha_register "array_status" "Array Status" "$topic" "" "" "harddisk" "" "$expire"
  mqtt_publish "$topic" "$status" "$retain"
}

publish_array_summary() {
  local expire="${1:-0}" retain="${2:-true}"
  local data; data=$(read_var_ini)
  [ -z "$data" ] && return
  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"

  local num_disks num_disabled num_invalid num_missing
  num_disks=$(var_field    "$data" mdNumDisks)
  num_disabled=$(var_field "$data" mdNumDisabled)
  num_invalid=$(var_field  "$data" mdNumInvalid)
  num_missing=$(var_field  "$data" mdNumMissing)

  [ -n "$num_disks" ] && {
    ha_register "array_num_disks" "Array Disk Count" \
      "${base}_array_num_disks/state" "" "" "harddisk" "" "$expire"
    mqtt_publish "${base}_array_num_disks/state" "$num_disks" "$retain"
  }
  [ -n "$num_disabled" ] && {
    ha_register "array_disabled_disks" "Array Disabled Disks" \
      "${base}_array_disabled_disks/state" "" "" "harddisk-remove" "" "$expire"
    mqtt_publish "${base}_array_disabled_disks/state" "$num_disabled" "$retain"
  }
  [ -n "$num_invalid" ] && {
    ha_register "array_invalid_disks" "Array Invalid Disks" \
      "${base}_array_invalid_disks/state" "" "" "alert-circle-outline" "" "$expire"
    mqtt_publish "${base}_array_invalid_disks/state" "$num_invalid" "$retain"
  }
  [ -n "$num_missing" ] && {
    ha_register "array_missing_disks" "Array Missing Disks" \
      "${base}_array_missing_disks/state" "" "" "harddisk-remove" "" "$expire"
    mqtt_publish "${base}_array_missing_disks/state" "$num_missing" "$retain"
  }

  local capacity free
  capacity=$(var_field "$data" mdCapacity)
  free=$(var_field     "$data" mdFree)

  if [ "${capacity:-0}" -gt 0 ] 2>/dev/null; then
    local cap_gb; cap_gb=$(awk "BEGIN{printf \"%.2f\", $capacity/1048576}")
    ha_register "array_capacity" "Array Capacity" \
      "${base}_array_capacity/state" "GB" "data_size" "harddisk" "" "$expire"
    mqtt_publish "${base}_array_capacity/state" "$cap_gb" "$retain"

    if [ "${free:-0}" -gt 0 ] 2>/dev/null; then
      local used_gb
      used_gb=$(awk "BEGIN{printf \"%.2f\", ($capacity-$free)/1048576}")
      ha_unregister "array_free"
      ha_register "array_used" "Array Used" \
        "${base}_array_used/state" "GB" "data_size" "harddisk" "" "$expire"
      mqtt_publish "${base}_array_used/state" "$used_gb" "$retain"
    fi
  fi
}

publish_cache() {
  local expire="${1:-0}" retain="${2:-true}"
  local data; data=$(read_var_ini)
  [ -z "$data" ] && return
  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"

  local cache_state cache_num cache_size cache_free cache_used
  cache_state=$(var_field "$data" cacheState)
  cache_num=$(var_field   "$data" cacheNumDevices)
  cache_size=$(var_field  "$data" cacheFsSize)
  cache_free=$(var_field  "$data" cacheFsFree)
  cache_used=$(var_field  "$data" cacheFsUsed)

  [ -n "$cache_state" ] && {
    ha_register "cache_state" "Cache State" \
      "${base}_cache_state/state" "" "" "lightning-bolt" "" "$expire"
    mqtt_publish "${base}_cache_state/state" "$cache_state" "$retain"
  }
  [ -n "$cache_num" ] && {
    ha_register "cache_num_devices" "Cache Devices" \
      "${base}_cache_num_devices/state" "" "" "lightning-bolt" "" "$expire"
    mqtt_publish "${base}_cache_num_devices/state" "$cache_num" "$retain"
  }

  if [ "${cache_size:-0}" -gt 0 ] 2>/dev/null; then
    local size_gb; size_gb=$(awk "BEGIN{printf \"%.2f\", $cache_size/1048576}")
    ha_register "cache_capacity" "Cache Capacity" \
      "${base}_cache_capacity/state" "GB" "data_size" "lightning-bolt" "" "$expire"
    mqtt_publish "${base}_cache_capacity/state" "$size_gb" "$retain"

    ha_unregister "cache_free"

    local used_kb="${cache_used}"
    [ "${used_kb:-0}" -le 0 ] 2>/dev/null && [ "${cache_free:-0}" -gt 0 ] 2>/dev/null && \
      used_kb=$(( cache_size - cache_free ))
    [ "${used_kb:-0}" -gt 0 ] 2>/dev/null && {
      local used_gb; used_gb=$(awk "BEGIN{printf \"%.2f\", $used_kb/1048576}")
      ha_register "cache_used" "Cache Used" \
        "${base}_cache_used/state" "GB" "data_size" "lightning-bolt" "" "$expire"
      mqtt_publish "${base}_cache_used/state" "$used_gb" "$retain"
    }
  fi
}

get_parity_info() {
  local data; data=$(read_var_ini)
  [ -z "$data" ] && echo "UNKNOWN|0|0" && return
  local action; action=$(var_field "$data" mdResyncAction)
  case "$action" in
    check|sync)
      local size pos dt db pct=0 speed=0
      size=$(var_field "$data" mdResyncSize)
      pos=$(var_field  "$data" mdResyncPos)
      dt=$(var_field   "$data" mdResyncDt)
      db=$(var_field   "$data" mdResyncDb)
      [ "${size:-0}" -gt 0 ] && pct=$(awk "BEGIN{printf \"%.1f\", $pos/$size*100}")
      [ "${dt:-0}" -gt 0 ]   && speed=$(awk "BEGIN{printf \"%.0f\", $db/$dt}")
      local state="RUNNING"; [ "$action" = "sync" ] && state="SYNC"
      echo "${state}|${pct}|${speed}"
      ;;
    *) echo "IDLE|0|0" ;;
  esac
}

publish_parity() {
  local expire="${1:-0}" retain="${2:-true}"
  local info; info=$(get_parity_info)
  local parity_state parity_pct parity_speed
  IFS='|' read -r parity_state parity_pct parity_speed <<< "$info"
  [ "$parity_state" = "UNKNOWN" ] && return

  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_parity"
  ha_register "parity_status"   "Parity Status"   "${base}_status/state"   ""     "" "shield-check"   "" "$expire"
  ha_register "parity_progress" "Parity Progress" "${base}_progress/state" "%"    "" "progress-check" "" "$expire"
  ha_register "parity_speed"    "Parity Speed"    "${base}_speed/state"    "KB/s" "" "speedometer"    "" "$expire"
  mqtt_publish "${base}_status/state"   "$parity_state"  "$retain"
  mqtt_publish "${base}_progress/state" "$parity_pct"    "$retain"
  mqtt_publish "${base}_speed/state"    "$parity_speed"  "$retain"
}

get_rebuild_info() {
  local data; data=$(read_var_ini)
  [ -z "$data" ] && echo "UNKNOWN|0|0|0" && return
  local action; action=$(var_field "$data" mdResyncAction)
  if [[ "$action" == recon* ]]; then
    local size pos dt db pct=0 speed=0 eta=0
    size=$(var_field "$data" mdResyncSize)
    pos=$(var_field  "$data" mdResyncPos)
    dt=$(var_field   "$data" mdResyncDt)
    db=$(var_field   "$data" mdResyncDb)
    local resync; resync=$(var_field "$data" mdResync)
    [ "${size:-0}" -eq 0 ] && echo "UNKNOWN|0|0|0" && return
    [ -z "$pos" ]          && echo "UNKNOWN|0|0|0" && return
    pct=$(awk "BEGIN{printf \"%.1f\", $pos/$size*100}")
    [ "${dt:-0}" -gt 0 ]    && speed=$(awk "BEGIN{printf \"%.0f\", $db/$dt}")
    [ "${speed:-0}" -gt 0 ] && eta=$(awk "BEGIN{printf \"%.0f\", ($size-$pos)/$speed/60}")
    local status="RUNNING"; [ "${resync:-1}" == "0" ] && status="PAUSED"
    echo "${status}|${pct}|${speed}|${eta}"
  else
    echo "IDLE|0|0|0"
  fi
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
  local check_file="/tmp/unraidcheck/result.json"
  local state_topic="${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_update_available/state"
  local attr_topic="${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_update_available/attributes"

  ha_register_binary "update_available" "Unraid Update Available" "$state_topic" "update" "package-up" "$expire" "$attr_topic"

  if [ ! -f "$check_file" ]; then
    mqtt_publish "$state_topic" "OFF" "$retain"
    mqtt_publish "$attr_topic" "{}" "$retain"
    return
  fi

  local result; result=$(cat "$check_file")
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
  local data; data=$(read_var_ini)
  [ -z "$data" ] && return
  local version; version=$(var_field "$data" version)
  [ -n "$version" ] && {
    local topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_unraid_version/state"
    ha_register "unraid_version" "Unraid Version" "$topic" "" "" "information-outline" "" "$expire"
    mqtt_publish "$topic" "$version" "$retain"
  }

  local server_name; server_name=$(var_field "$data" NAME)
  [ -n "$server_name" ] && {
    local state_topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_identification/state"
    local attr_topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_identification/attributes"
    ha_register "identification" "Identification" "$state_topic" "" "" "server" "" "$expire" "$attr_topic"
    mqtt_publish "$state_topic" "$server_name" "$retain"

    local description model
    description=$(var_field "$data" COMMENT)
    model=$(var_field       "$data" SYS_MODEL)

    local attrs
    attrs=$(printf '{"server_name":"%s","description":"%s","model":"%s","version":"%s"}' \
      "$server_name" "$description" "$model" "${version:-}")
    mqtt_publish "$attr_topic" "$attrs" "$retain"
  }
}

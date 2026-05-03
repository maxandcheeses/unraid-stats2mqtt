#!/bin/bash
# SOURCE: Unraid GraphQL API (array disks/parities/caches)

# Removes HA discovery registrations for a disk that is no longer present (DISK_NP status).
_unregister_disk_sensors() {
  local sn; sn=$(safe_name "$1")
  ha_unregister "${sn}_state"
  ha_unregister "${sn}_temp"
  ha_unregister "${sn}"
  ha_unregister "${sn}_errors"
}

# Publishes temperature sensor for each array disk and parity. Skips disks with no temp or DISK_NP status.
publish_disk_temps() {
  local expire="${1:-0}" retain="${2:-true}"
  local arr; arr=$(get_array_data) || return

  while IFS=$'\t' read -r name temp status; do
    [[ "$status" == DISK_NP* ]] && continue
    [ -z "$temp" ] || [ "$temp" = "null" ] && continue
    local sn; sn=$(safe_name "$name")
    local topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${sn}_temp/state"
    ha_register "${sn}_temp" "${name} Temperature" "$topic" "°C" "temperature" "thermometer" "" "$expire"
    mqtt_publish "$topic" "$temp" "$retain"
  done < <(echo "$arr" | jq -r '(.data.array.disks[], .data.array.parities[]) | [.name, (.temp // ""), .status] | @tsv')
}

publish_disk_states() {
  local expire="${1:-0}" retain="${2:-true}"
  local arr; arr=$(get_array_data) || return

  while IFS=$'\t' read -r name status is_spinning; do
    local sn; sn=$(safe_name "$name")
    local state
    case "$status" in
      DISK_OK)
        if [ "$is_spinning" = "false" ]; then
          state="STANDBY"
        else
          state="ACTIVE"
        fi
        ;;
      DISK_DSBL) state="DISABLED" ;;
      DISK_NP*)
        _unregister_disk_sensors "$name"
        continue
        ;;
      *) state="ACTIVE" ;;
    esac
    local topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${sn}_state/state"
    ha_register "${sn}_state" "${name} State" "$topic" "" "" "harddisk" "" "$expire"
    mqtt_publish "$topic" "$state" "$retain"
  done < <(echo "$arr" | jq -r '.data.array.disks[] | [.name, .status, (.isSpinning // true | tostring)] | @tsv')
}

publish_disk_usage() {
  local expire="${1:-0}" retain="${2:-true}"
  local arr; arr=$(get_array_data) || return

  while IFS=$'\t' read -r name status fs_size fs_free fs_used; do
    [[ "$status" == DISK_NP* ]] && continue
    [ "${fs_size:-0}" -le 0 ] 2>/dev/null && continue

    local sn; sn=$(safe_name "$name")
    local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${sn}"

    local used_kb="${fs_used}"
    [ "${used_kb:-0}" -le 0 ] 2>/dev/null && [ "${fs_free:-0}" -gt 0 ] 2>/dev/null && \
      used_kb=$(( fs_size - fs_free ))

    local used_pct; used_pct=$(awk "BEGIN{printf \"%.1f\", ($fs_size-${fs_free:-0})/$fs_size*100}")
    local size_gb;  size_gb=$(awk  "BEGIN{printf \"%.2f\", $fs_size/1048576}")
    local free_gb;  free_gb=$(awk  "BEGIN{printf \"%.2f\", ${fs_free:-0}/1048576}")
    local used_gb;  used_gb=$(awk  "BEGIN{printf \"%.2f\", ${used_kb:-0}/1048576}")

    local attr_json="{\"size_gb\":$size_gb,\"free_gb\":$free_gb,\"used_gb\":$used_gb}"
    local attr_topic="${base}/attributes"
    ha_register "${sn}" "${name} Usage" "${base}/state" "%" "" "harddisk" "" "$expire" "$attr_topic"
    mqtt_publish "${base}/state" "$used_pct" "$retain"
    mqtt_publish "$attr_topic" "$attr_json" "$retain"
  done < <(echo "$arr" | jq -r '.data.array.disks[] | [.name, .status, (.fsSize // 0), (.fsFree // 0), (.fsUsed // 0)] | @tsv')
}

publish_disk_errors() {
  local expire="${1:-0}" retain="${2:-true}"
  local arr; arr=$(get_array_data) || return

  while IFS=$'\t' read -r name status errors color; do
    [[ "$status" == DISK_NP* ]] && continue
    local sn; sn=$(safe_name "$name")
    local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${sn}"

    [ -n "$errors" ] && [ "$errors" != "null" ] && {
      ha_register "${sn}_errors" "${name} Errors" "${base}_errors/state" "" "" "alert-circle" "" "$expire"
      mqtt_publish "${base}_errors/state" "$errors" "$retain"
    }
  done < <(echo "$arr" | jq -r '.data.array.disks[] | [.name, .status, (.numErrors // ""), (.color // "")] | @tsv')
}

#!/bin/bash
# SOURCE: Unraid GraphQL API (virtual machines)

publish_vms() {
  local expire="${1:-0}" retain="${2:-false}"
  local mode="${VM_SENSOR_MODE:-include}"
  local list="${VM_SENSORS:-}"

  local data; data=$(get_vms_data) || return

  if echo "$data" | jq -e '.errors' >/dev/null 2>&1; then
    log "DEBUG: VMs not available — skipping VM publish"
    return
  fi

  while IFS= read -r vm_json; do
    local name state raw_id uuid
    name=$(echo "$vm_json"   | jq -r '.name // ""')
    state=$(echo "$vm_json"  | jq -r '.state // ""')
    raw_id=$(echo "$vm_json" | jq -r '.id // ""')
    uuid="${raw_id##*:}"

    if [ "$mode" = "include" ]; then
      [ -z "$list" ] && continue
      echo ",$list," | grep -qF ",${name}," || continue
    else
      [ -n "$list" ] && echo ",$list," | grep -qF ",${name}," && continue
    fi

    local sn; sn=$(safe_name "$name")
    local uid="vm_${sn}"
    local state_topic="${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_${uid}/state"
    local attr_topic="${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_${uid}/attributes"

    ha_register_binary "$uid" "${name}" "$state_topic" "" "desktop-tower-monitor" "$expire" "$attr_topic"

    local value="OFF"
    [ "$state" = "RUNNING" ] && value="ON"
    mqtt_publish "$state_topic" "$value" "$retain"

    local attrs
    attrs=$(printf '{"name":"%s","state":"%s","uuid":"%s"}' \
      "$(json_escape "$name")" "$(json_escape "$state")" "$(json_escape "$uuid")")
    mqtt_publish "$attr_topic" "$attrs" "$retain"
  done < <(echo "$data" | jq -c '.data.vms.domain[]')
}

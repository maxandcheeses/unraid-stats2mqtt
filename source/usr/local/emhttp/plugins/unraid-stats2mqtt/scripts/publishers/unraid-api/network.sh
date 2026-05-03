#!/bin/bash
# SOURCE: Unraid GraphQL API (info.networkInterfaces)

# Publishes one sensor per non-internal network interface showing operstate,
# with IP, MAC, speed, and type as JSON attributes.
publish_network() {
  local expire="${1:-0}" retain="${2:-true}"
  local data; data=$(get_network_data) || return

  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"

  while IFS= read -r iface_json; do
    local iface; iface=$(echo "$iface_json" | jq -r '.iface // empty')
    [ -z "$iface" ] && continue
    local internal; internal=$(echo "$iface_json" | jq -r '.internal // false')
    [ "$internal" = "true" ] && continue

    local operstate; operstate=$(echo "$iface_json" | jq -r '.operstate // "unknown"')
    local safe; safe=$(safe_name "$iface")
    local uid="net_${safe}"
    local attrs; attrs=$(echo "$iface_json" | jq -c '{ip4, ip4subnet, ip6, mac, speed, type, operstate}')

    ha_register "$uid" "Network ${iface}" \
      "${base}_${uid}/state" "" "" "ethernet" "" "$expire" \
      "${base}_${uid}/attributes"
    mqtt_publish "${base}_${uid}/state" "$operstate" "$retain"
    mqtt_publish "${base}_${uid}/attributes" "$attrs" "$retain"
  done < <(echo "$data" | jq -c '.data.info.networkInterfaces[]? // empty')
}

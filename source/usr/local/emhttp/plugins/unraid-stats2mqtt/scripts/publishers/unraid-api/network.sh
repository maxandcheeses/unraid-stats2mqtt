#!/bin/bash
# SOURCE: Unraid GraphQL API (info.networkInterfaces)

# Publishes one sensor per network interface showing its status,
# with IP, MAC, gateway, protocol, and DHCP config as JSON attributes.
# Skips the loopback interface (name "lo").
publish_network() {
  local expire="${1:-0}" retain="${2:-true}"
  local data; data=$(get_network_data) || return

  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"
  local primary_name; primary_name=$(echo "$data" | jq -r '.data.info.primaryNetwork.name // empty')

  while IFS= read -r iface_json; do
    local name; name=$(echo "$iface_json" | jq -r '.name // empty')
    [ -z "$name" ] || [ "$name" = "lo" ] && continue

    local status; status=$(echo "$iface_json" | jq -r '.status // "unknown"')
    local safe; safe=$(safe_name "$name")
    local uid="net_${safe}"
    local display_name="Network ${name}"
    [ "$name" = "$primary_name" ] && display_name="Network ${name} (primary)"

    local attrs; attrs=$(echo "$iface_json" | jq -c '{
      description,
      macAddress,
      protocol,
      ipAddress,
      netmask,
      gateway,
      useDhcp,
      ipv6Address,
      ipv6Netmask,
      ipv6Gateway,
      useDhcp6
    }')

    ha_register "$uid" "$display_name" \
      "${base}_${uid}/state" "" "" "ethernet" "" "$expire" \
      "${base}_${uid}/attributes"
    mqtt_publish "${base}_${uid}/state" "$status" "$retain"
    mqtt_publish "${base}_${uid}/attributes" "$attrs" "$retain"
  done < <(echo "$data" | jq -c '.data.info.networkInterfaces[]? // empty')
}

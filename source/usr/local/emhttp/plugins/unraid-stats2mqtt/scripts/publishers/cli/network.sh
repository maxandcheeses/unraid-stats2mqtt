#!/bin/bash

publish_network() {
  local expire="${1:-0}" retain="${2:-true}"

  while IFS=$'\t' read -r sec idx kiface ip description vlanid gateway mac type \
      rx_bytes tx_bytes rx_packets tx_packets rx_errs tx_errs rx_drop tx_drop; do

    local uid; uid=$(safe_name "net_${sec}_${idx}_network")
    local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${uid}"
    local attr_topic="${base}/attributes"
    local label="${description:-${sec}:${idx}} Network"

    ha_register "$uid" "$label" "${base}/state" "" "" "lan" "" "$expire" "$attr_topic"
    mqtt_publish "${base}/state" "$ip" "$retain"

    local attrs
    attrs=$(printf '{"description":"%s","vlanid":"%s","gateway":"%s","mac":"%s","type":"%s","interface":"%s","rx_bytes":%d,"tx_bytes":%d,"rx_errors":%d,"tx_errors":%d,"rx_drops":%d,"tx_drops":%d}' \
      "$(json_escape "$description")" "${vlanid:-untagged}" \
      "$gateway" "$mac" "$type" "$kiface" \
      "$rx_bytes" "$tx_bytes" \
      "$rx_errs" "$tx_errs" \
      "$rx_drop" "$tx_drop")
    mqtt_publish "$attr_topic" "$attrs" "$retain"
  done < <(collect_network_interfaces)
}

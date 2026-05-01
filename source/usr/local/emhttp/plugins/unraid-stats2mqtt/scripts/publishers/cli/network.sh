#!/bin/bash
declare -A PREV_NET_RX PREV_NET_TX PREV_NET_TIME

publish_network_speeds() {
  local expire="${1:-0}" retain="${2:-true}"
  local now; now=$(date +%s)

  while IFS=$'\t' read -r sec idx kiface ip description vlanid gateway mac type \
      rx_bytes tx_bytes rx_packets tx_packets rx_errs tx_errs rx_drop tx_drop; do

    local rx_speed=0 tx_speed=0
    if [ -n "${PREV_NET_RX[$kiface]+x}" ]; then
      local elapsed=$(( now - PREV_NET_TIME[$kiface] ))
      [ "$elapsed" -le 0 ] && elapsed=1
      rx_speed=$(( (rx_bytes - PREV_NET_RX[$kiface]) / elapsed / 1024 ))
      tx_speed=$(( (tx_bytes - PREV_NET_TX[$kiface]) / elapsed / 1024 ))
    fi
    PREV_NET_RX[$kiface]="$rx_bytes"
    PREV_NET_TX[$kiface]="$tx_bytes"
    PREV_NET_TIME[$kiface]="$now"

    local uid; uid=$(safe_name "net_${sec}_${idx}_network")
    local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${uid}"
    local attr_topic="${base}/attributes"
    local label="${description:-${sec}:${idx}} Network"

    ha_register "$uid" "$label" "${base}/state" "" "" "lan" "" "$expire" "$attr_topic"
    mqtt_publish "${base}/state" "$ip" "$retain"

    local attrs
    attrs=$(printf '{"description":"%s","vlanid":"%s","gateway":"%s","mac":"%s","type":"%s","interface":"%s","rx_speed_kbs":%d,"tx_speed_kbs":%d,"rx_bytes":%d,"tx_bytes":%d,"rx_errors":%d,"tx_errors":%d,"rx_drops":%d,"tx_drops":%d}' \
      "$(json_escape "$description")" "${vlanid:-untagged}" \
      "$gateway" "$mac" "$type" "$kiface" \
      "$rx_speed" "$tx_speed" \
      "$rx_bytes" "$tx_bytes" \
      "$rx_errs" "$tx_errs" \
      "$rx_drop" "$tx_drop")
    mqtt_publish "$attr_topic" "$attrs" "$retain"
  done < <(collect_network_interfaces)
}

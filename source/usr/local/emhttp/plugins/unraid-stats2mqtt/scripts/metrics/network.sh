#!/bin/bash
# SOURCE: /var/local/emhttp/network.ini, /proc/net/dev, /sys/class/net
# One sensor per logical sub-interface that has an IPADDR
# State: IP address
# Attributes: description, vlanid, gateway, mac, type, speeds, totals

declare -A PREV_NET_RX PREV_NET_TX PREV_NET_TIME

_net_snapshot() {
  while read -r iface rx_bytes rx_packets rx_errs rx_drop tx_bytes tx_packets tx_errs tx_drop; do
    [ "$iface" = "lo" ] && continue
    SNAP_RX[$iface]=$rx_bytes;        SNAP_TX[$iface]=$tx_bytes
    SNAP_PKT_RX[$iface]=$rx_packets;  SNAP_PKT_TX[$iface]=$tx_packets
    SNAP_ERR_RX[$iface]=$rx_errs;     SNAP_ERR_TX[$iface]=$tx_errs
    SNAP_DROP_RX[$iface]=$rx_drop;    SNAP_DROP_TX[$iface]=$tx_drop
  done < <(awk 'NR>2 { gsub(/:/, "", $1); print $1, $2, $3, $4, $5, $10, $11, $12, $13 }' /proc/net/dev 2>/dev/null)
}

_ifield() { echo "$1" | grep -E "^${2}:${3}=" | head -1 | cut -d= -f2- | tr -d '"'; }
_field()  { echo "$1" | grep -E "^${2}="      | head -1 | cut -d= -f2- | tr -d '"'; }
_indices() { echo "$1" | grep -oE ':[0-9]+=' | tr -d ':=' | sort -nu; }

publish_network_speeds() {
  local expire="${1:-0}" retain="${2:-true}"
  local now; now=$(date +%s)
  local net_ini="/var/local/emhttp/network.ini"
  [ ! -f "$net_ini" ] && return

  declare -A SNAP_RX SNAP_TX SNAP_PKT_RX SNAP_PKT_TX SNAP_ERR_RX SNAP_ERR_TX SNAP_DROP_RX SNAP_DROP_TX
  _net_snapshot

  local current_section="" section_blob=""
  _process_section() {
    local sec="$1" blob="$2"
    [ -z "$sec" ] && return

    local bridging; bridging=$(_field "$blob" "BRIDGING")
    local brname;   brname=$(_field   "$blob" "BRNAME")
    local bonding;  bonding=$(_field  "$blob" "BONDING")
    local bondname; bondname=$(_field "$blob" "BONDNAME")
    local type;     type=$(_field     "$blob" "TYPE")
    local mac;      mac=$(cat "/sys/class/net/${sec}/address" 2>/dev/null)

    for idx in $(_indices "$blob"); do
      local ip;          ip=$(_ifield          "$blob" "IPADDR"      "$idx")
      local description; description=$(_ifield "$blob" "DESCRIPTION" "$idx")
      local vlanid;      vlanid=$(_ifield      "$blob" "VLANID"      "$idx")
      local gateway;     gateway=$(_ifield     "$blob" "GATEWAY"     "$idx")

      [ -z "$ip" ] && ip="UNKNOWN"

      local kiface="$sec"
      [ "$bonding"  = "yes" ] && kiface="$bondname"
      [ "$bridging" = "yes" ] && kiface="$brname"
      [ -n "$vlanid" ] && [ "$bridging" = "yes" ]  && kiface="${brname}.${vlanid}"
      [ -n "$vlanid" ] && [ "$bridging" != "yes" ] && [ "$bonding" != "yes" ] && kiface="${sec}.${vlanid}"

      local uid; uid=$(safe_name "net_${sec}_${idx}_network")
      local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${uid}"
      local attr_topic="${base}/attributes"
      local label="${description:-${sec}:${idx}} Network"

      local rx_speed=0 tx_speed=0
      local rx_bytes="${SNAP_RX[$kiface]:-0}"       tx_bytes="${SNAP_TX[$kiface]:-0}"
      local rx_packets="${SNAP_PKT_RX[$kiface]:-0}" tx_packets="${SNAP_PKT_TX[$kiface]:-0}"
      local rx_errs="${SNAP_ERR_RX[$kiface]:-0}"    tx_errs="${SNAP_ERR_TX[$kiface]:-0}"
      local rx_drop="${SNAP_DROP_RX[$kiface]:-0}"   tx_drop="${SNAP_DROP_TX[$kiface]:-0}"

      if [ -n "${PREV_NET_RX[$kiface]+x}" ]; then
        local elapsed=$(( now - PREV_NET_TIME[$kiface] ))
        [ "$elapsed" -le 0 ] && elapsed=1
        rx_speed=$(( (rx_bytes - PREV_NET_RX[$kiface]) / elapsed / 1024 ))
        tx_speed=$(( (tx_bytes - PREV_NET_TX[$kiface]) / elapsed / 1024 ))
      fi
      PREV_NET_RX[$kiface]="$rx_bytes"
      PREV_NET_TX[$kiface]="$tx_bytes"
      PREV_NET_TIME[$kiface]="$now"

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
    done
  }

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      _process_section "$current_section" "$section_blob"
      current_section="${BASH_REMATCH[1]}"
      section_blob=""
    else
      section_blob+="${line}"$'\n'
    fi
  done < "$net_ini"
  _process_section "$current_section" "$section_blob"
}

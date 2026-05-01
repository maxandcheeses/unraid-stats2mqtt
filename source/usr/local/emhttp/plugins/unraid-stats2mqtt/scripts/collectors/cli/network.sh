#!/bin/bash
# SOURCE: /var/local/emhttp/network.ini, /proc/net/dev, /sys/class/net

_net_field()   { echo "$1" | grep -E "^${2}="      | head -1 | cut -d= -f2- | tr -d '"'; }
_net_ifield()  { echo "$1" | grep -E "^${2}:${3}=" | head -1 | cut -d= -f2- | tr -d '"'; }
_net_indices() { echo "$1" | grep -oE ':[0-9]+=' | tr -d ':=' | sort -nu; }

# Outputs tab-separated lines per sub-interface:
# section idx kiface ip description vlanid gateway mac type rx_bytes tx_bytes rx_packets tx_packets rx_errs tx_errs rx_drop tx_drop
collect_network_interfaces() {
  local net_ini="/var/local/emhttp/network.ini"
  [ ! -f "$net_ini" ] && return 1

  declare -A snap_rx snap_tx snap_pkt_rx snap_pkt_tx snap_err_rx snap_err_tx snap_drop_rx snap_drop_tx
  while read -r iface rx_bytes rx_packets rx_errs rx_drop tx_bytes tx_packets tx_errs tx_drop; do
    [ "$iface" = "lo" ] && continue
    snap_rx[$iface]=$rx_bytes;        snap_tx[$iface]=$tx_bytes
    snap_pkt_rx[$iface]=$rx_packets;  snap_pkt_tx[$iface]=$tx_packets
    snap_err_rx[$iface]=$rx_errs;     snap_err_tx[$iface]=$tx_errs
    snap_drop_rx[$iface]=$rx_drop;    snap_drop_tx[$iface]=$tx_drop
  done < <(awk 'NR>2 { gsub(/:/, "", $1); print $1, $2, $3, $4, $5, $10, $11, $12, $13 }' /proc/net/dev 2>/dev/null)

  _emit_section() {
    local sec="$1" blob="$2"
    [ -z "$sec" ] && return

    local bridging; bridging=$(_net_field "$blob" "BRIDGING")
    local brname;   brname=$(_net_field   "$blob" "BRNAME")
    local bonding;  bonding=$(_net_field  "$blob" "BONDING")
    local bondname; bondname=$(_net_field "$blob" "BONDNAME")
    local type;     type=$(_net_field     "$blob" "TYPE")
    local mac;      mac=$(cat "/sys/class/net/${sec}/address" 2>/dev/null)

    for idx in $(_net_indices "$blob"); do
      local ip;          ip=$(_net_ifield          "$blob" "IPADDR"      "$idx")
      local description; description=$(_net_ifield "$blob" "DESCRIPTION" "$idx")
      local vlanid;      vlanid=$(_net_ifield      "$blob" "VLANID"      "$idx")
      local gateway;     gateway=$(_net_ifield     "$blob" "GATEWAY"     "$idx")

      [ -z "$ip" ] && ip="UNKNOWN"

      local kiface="$sec"
      [ "$bonding"  = "yes" ] && kiface="$bondname"
      [ "$bridging" = "yes" ] && kiface="$brname"
      [ -n "$vlanid" ] && [ "$bridging" = "yes" ]  && kiface="${brname}.${vlanid}"
      [ -n "$vlanid" ] && [ "$bridging" != "yes" ] && [ "$bonding" != "yes" ] && kiface="${sec}.${vlanid}"

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sec" "$idx" "$kiface" "$ip" "$description" "$vlanid" "$gateway" "$mac" "$type" \
        "${snap_rx[$kiface]:-0}" "${snap_tx[$kiface]:-0}" \
        "${snap_pkt_rx[$kiface]:-0}" "${snap_pkt_tx[$kiface]:-0}" \
        "${snap_err_rx[$kiface]:-0}" "${snap_err_tx[$kiface]:-0}" \
        "${snap_drop_rx[$kiface]:-0}" "${snap_drop_tx[$kiface]:-0}"
    done
  }

  local current_section="" section_blob=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      _emit_section "$current_section" "$section_blob"
      current_section="${BASH_REMATCH[1]}"
      section_blob=""
    else
      section_blob+="${line}"$'\n'
    fi
  done < "$net_ini"
  _emit_section "$current_section" "$section_blob"
}

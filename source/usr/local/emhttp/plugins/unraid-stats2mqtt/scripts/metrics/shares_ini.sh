#!/bin/bash
# SOURCE: shares.ini
# Publishes one JSON sensor per share containing all raw ini fields.

publish_shares() {
  local expire="${1:-0}" retain="${2:-true}"
  local shares_file="/var/local/emhttp/shares.ini"
  [ ! -f "$shares_file" ] && return

  local cur_share=""
  local -A cur_fields

  _flush_share_json() {
    [ -z "$cur_share" ] && return
    local sn; sn=$(safe_name "$cur_share")
    local topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_share_${sn}_info/state"

    local json="{\"share\":\"$(json_escape "$cur_share")\""
    local k
    for k in "${!cur_fields[@]}"; do
      json+=",\"$(json_escape "$k")\":\"$(json_escape "${cur_fields[$k]}")\""
    done
    json+="}"

    ha_register "share_${sn}_info" "${cur_share} Usage" "$topic" "%" "" "folder" "{{ 0 if (value_json.used | int + value_json.free | int) == 0 else (value_json.used | int / (value_json.used | int + value_json.free | int) * 100) | round(1) }}" "$expire" "$topic"
    mqtt_publish "$topic" "$json" "$retain"
  }

  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      _flush_share_json
      cur_share="${BASH_REMATCH[1]//\"/}"; cur_fields=()
    fi
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]//\"/}"
      cur_fields[$k]="$v"
    fi
  done < "$shares_file"
  _flush_share_json
}

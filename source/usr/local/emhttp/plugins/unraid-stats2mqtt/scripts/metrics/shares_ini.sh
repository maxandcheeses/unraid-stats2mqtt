#!/bin/bash
# SOURCE: Unraid GraphQL API (shares)

publish_shares() {
  local expire="${1:-0}" retain="${2:-true}"
  local shares; shares=$(get_shares_data) || return

  while IFS=$'\t' read -r name free used size comment color; do
    local sn; sn=$(safe_name "$name")
    local topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_share_${sn}_info/state"
    local json
    json=$(printf '{"share":"%s","free":%s,"used":%s,"size":%s,"comment":"%s","color":"%s"}' \
      "$(json_escape "$name")" "${free:-0}" "${used:-0}" "${size:-0}" \
      "$(json_escape "$comment")" "$(json_escape "$color")")
    ha_register "share_${sn}_info" "${name} Usage" "$topic" "%" "" "folder" \
      "{{ 0 if (value_json.used | int + value_json.free | int) == 0 else (value_json.used | int / (value_json.used | int + value_json.free | int) * 100) | round(1) }}" \
      "$expire" "$topic"
    mqtt_publish "$topic" "$json" "$retain"
  done < <(echo "$shares" | jq -r '.data.shares[] | [.name, (.free // 0), (.used // 0), (.size // 0), (.comment // ""), (.color // "")] | @tsv')
}

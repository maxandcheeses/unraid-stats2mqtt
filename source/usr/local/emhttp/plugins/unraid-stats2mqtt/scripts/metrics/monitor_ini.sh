#!/bin/bash
# SOURCE: Unraid GraphQL API (vars, parityHistory)

publish_monitor() {
  local expire="${1:-0}" retain="${2:-true}"
  local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}"

  local vars; vars=$(get_vars_data) || return
  local sync_errs; sync_errs=$(echo "$vars" | jq -r '.data.vars.sbSyncErrs // empty')
  [ -n "$sync_errs" ] && {
    ha_register "monitor_array_errors" "Array Errors" \
      "${base}_monitor_array_errors/state" "" "" "alert" "" "$expire"
    mqtt_publish "${base}_monitor_array_errors/state" "$sync_errs" "$retain"
  }

  local hist; hist=$(get_parity_history_data) || return
  local last_status; last_status=$(echo "$hist" | jq -r '.data.parityHistory[0].status // empty')
  [ -n "$last_status" ] && {
    local parity_hist_json
    parity_hist_json=$(echo "$hist" | jq -c '.data.parityHistory[0] | {date, duration, speed, status, errors}')
    local parity_hist_attrs
    parity_hist_attrs=$(echo "$hist" | jq -c '{history: [.data.parityHistory[] | {date, duration, speed, status, errors}]}')
    ha_register "monitor_parity_history" "Parity History" \
      "${base}_monitor_parity_history/state" \
      "" "" "shield-check" "" "$expire" \
      "${base}_monitor_parity_history/attributes"
    mqtt_publish "${base}_monitor_parity_history/state" "$last_status" "$retain"
    mqtt_publish "${base}_monitor_parity_history/attributes" "$parity_hist_attrs" "$retain"
  }
}

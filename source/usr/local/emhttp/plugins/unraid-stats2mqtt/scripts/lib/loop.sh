#!/bin/bash

state_changed() {
  local key="$1" new_val="$2"
  local state_file="$STATE_DIR/${key}.state"
  local old_val=""; [ -f "$state_file" ] && old_val=$(cat "$state_file")
  if [ "$old_val" != "$new_val" ]; then
    echo "$new_val" > "$state_file"
    return 0
  fi
  return 1
}

should_publish_interval() {
  local key="$1" interval="$2" tick="$3"
  local tick_file="$STATE_DIR/${key}.tick"
  local last_tick=0; [ -f "$tick_file" ] && last_tick=$(cat "$tick_file")
  (( last_tick > tick )) && last_tick=0
  if (( tick - last_tick >= interval )); then
    echo "$tick" > "$tick_file"
    return 0
  fi
  return 1
}

# Usage: _publish_metric <key> <mode> <interval> <expire> <fn> [snap_cmd] [retain]
_publish_metric() {
  local key="$1" mode="$2" interval="$3" expire="$4" fn="$5" snap_cmd="${6:-}" retain="${7:-true}"
  local _published=0

  if [[ "$mode" == "onchange" || "$mode" == "both" ]] && [ -n "$snap_cmd" ]; then
    local snap; snap=$(eval "$snap_cmd")
    if state_changed "$key" "$snap"; then
      log "State change publish: $key"
      "$fn" "$expire" "$retain"
      _published=1
    fi
  fi
  if [[ "$mode" == "interval" || "$mode" == "both" ]]; then
    if [[ "$_published" -eq 0 ]] && should_publish_interval "${key}_interval" "$interval" "$TICK"; then
      log "Interval publish: $key"
      "$fn" "$expire" "$retain"
    fi
  fi
}

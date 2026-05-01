#!/bin/bash

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

# Usage: _publish_metric <key> <interval> <expire> <fn> [retain]
# interval=0 disables the metric
_publish_metric() {
  local key="$1" interval="$2" expire="$3" fn="$4" retain="${5:-true}"
  [ "${interval:-0}" -le 0 ] 2>/dev/null && return
  if should_publish_interval "${key}_interval" "$interval" "$TICK"; then
    log "Interval publish: $key"
    "$fn" "$expire" "$retain"
  fi
}

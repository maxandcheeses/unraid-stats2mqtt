#!/bin/bash
# SOURCE: /proc/diskstats

# usage: collect_diskstats <dev>
# outputs: read_bytes write_bytes
collect_diskstats() {
  local dev="$1"
  local stats; stats=$(awk -v d=" $dev " '$0~d{print;exit}' /proc/diskstats 2>/dev/null)
  [ -z "$stats" ] && return 1
  local read_bytes write_bytes
  read_bytes=$(( $(echo "$stats" | awk '{print $6}') * 512 ))
  write_bytes=$(( $(echo "$stats" | awk '{print $10}') * 512 ))
  echo "$read_bytes $write_bytes"
}

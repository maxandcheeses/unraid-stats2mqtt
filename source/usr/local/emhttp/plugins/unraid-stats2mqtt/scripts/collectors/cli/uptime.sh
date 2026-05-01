#!/bin/bash
# SOURCE: /proc/uptime

collect_uptime() {
  awk '{printf "%d", $1}' /proc/uptime 2>/dev/null
}

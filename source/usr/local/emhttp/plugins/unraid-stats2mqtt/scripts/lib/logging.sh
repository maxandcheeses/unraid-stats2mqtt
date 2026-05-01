#!/bin/bash

log() {
  if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv "$LOG_FILE" "${LOG_FILE}.1"
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_syslog() {
  logger -t unraid-stats2mqtt "$1"
}

# Call from: trap 'on_exit $?' EXIT
on_exit() {
  local rc="$1"
  if [ "${rc}" -ne 0 ] && [ "${_CLEAN_EXIT:-0}" = "0" ]; then
    local msg="Daemon exited unexpectedly (exit ${rc})"
    log "ERROR: ${msg}"
    log_syslog "ERROR: ${msg}"
  fi
}

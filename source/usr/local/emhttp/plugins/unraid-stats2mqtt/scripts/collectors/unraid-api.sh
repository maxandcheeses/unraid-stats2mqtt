#!/bin/bash

declare -A _API_CACHE
declare -A _API_CACHE_TICK

# Sends a GraphQL query to the Unraid API and returns the raw JSON response.
# Requires UNRAID_API_KEY and UNRAID_API_HOST. Returns 1 on network failure or API error.
graphql_query() {
  local query="$1"
  if [ -z "${UNRAID_API_KEY:-}" ]; then
    log "WARN: UNRAID_API_KEY not configured — skipping API query"
    return 1
  fi
  local payload; payload=$(jq -n --arg q "$query" '{"query":$q}')
  local host="${UNRAID_API_HOST:-http://localhost}"
  local response
  response=$(curl -skL --connect-timeout 5 --max-time 10 \
    -X POST "${host}/graphql" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${UNRAID_API_KEY}" \
    -H "apollo-require-preflight: true" \
    -d "$payload" 2>/dev/null)
  local rc=$?
  if [ $rc -ne 0 ] || [ -z "$response" ]; then
    log "WARN: Unraid API request failed (curl exit $rc)"
    return 1
  fi
  if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    local msg; msg=$(echo "$response" | jq -r '.errors[0].message // "unknown"')
    log "WARN: Unraid API error: $msg"
    return 1
  fi
  echo "$response"
}

# Wraps graphql_query with a per-tick in-memory cache keyed by $key.
# Repeated calls within the same TICK return the cached result without a network round-trip.
_api_cached() {
  local key="$1" query="$2"
  if [ "${_API_CACHE_TICK[$key]:-}" = "${TICK}" ] && [ -n "${_API_CACHE[$key]+x}" ]; then
    echo "${_API_CACHE[$key]}"
    return 0
  fi
  local result; result=$(graphql_query "$query") || return 1
  _API_CACHE[$key]="$result"
  _API_CACHE_TICK[$key]="$TICK"
  echo "$result"
}

# Returns array state, capacity, per-disk status/temp/errors/usage, parity check status, and cache pool info.
get_array_data() {
  _api_cached "array" '{ array { state capacity { kilobytes { free used total } disks { free used total } } parities { name device status temp numErrors type } disks { name device status temp numErrors fsSize fsFree fsUsed type color isSpinning } caches { name device status fsSize fsFree fsUsed } parityCheckStatus { date duration speed status errors progress running paused } } }'
}

# Returns server identity, Unraid version, array disk counts, resync state, and registration info.
get_vars_data() {
  _api_cached "vars" '{ vars { version name sysModel mdNumDisks mdNumDisabled mdNumInvalid mdNumMissing mdColor mdState mdResync mdResyncAction mdResyncPos mdResyncDb mdResyncDt sbSyncErrs flashGuid regState } }'
}

# Returns all user shares with name, size, free/used, comment, and color.
get_shares_data() {
  _api_cached "shares" '{ shares { name free used size comment color } }'
}

# Returns the historical parity check log (date, duration, speed, status, errors per run).
get_parity_history_data() {
  _api_cached "parityHistory" '{ parityHistory { date duration speed status errors } }'
}

# Returns OS info (hostname, platform, uptime, kernel, arch) and CPU info (brand, cores, threads).
get_info_data() {
  _api_cached "info" '{ info { os { hostname platform uptime kernel arch } cpu { brand cores threads } } }'
}

# Returns all Docker containers with state, status, image, autostart, and port mappings.
get_docker_data() {
  _api_cached "docker" '{ docker { containers { id names state status image imageId autoStart ports { ip privatePort publicPort type } } } }'
}

# Returns all VMs with id, name, and current domain state.
get_vms_data() {
  _api_cached "vms" '{ vms { domain { id name state } } }'
}

# Returns the array state string (e.g. "STARTED", "STOPPED"). Returns "UNKNOWN" on API failure.
get_array_status() {
  local resp; resp=$(get_array_data) || { echo "UNKNOWN"; return; }
  echo "$resp" | jq -r '.data.array.state // "UNKNOWN"'
}

get_parity_info() {
  local arr; arr=$(get_array_data) || { echo "UNKNOWN|0|0"; return; }
  local running; running=$(echo "$arr" | jq -r '.data.array.parityCheckStatus.running // empty')

  if [ "$running" = "true" ]; then
    local progress speed
    progress=$(echo "$arr" | jq -r '.data.array.parityCheckStatus.progress // 0')
    speed=$(echo    "$arr" | jq -r '.data.array.parityCheckStatus.speed    // "0"')
    echo "RUNNING|${progress}|${speed}"
  else
    echo "IDLE|0|0"
  fi
}

get_rebuild_info() {
  local vars; vars=$(get_vars_data) || { echo "UNKNOWN|0|0|0"; return; }
  local action; action=$(echo "$vars" | jq -r '.data.vars.mdResyncAction // empty')

  if [[ "$action" == recon* ]]; then
    local resync pos size db dt pct=0 speed=0 eta=0
    resync=$(echo "$vars" | jq -r '.data.vars.mdResync    // 0')
    pos=$(echo    "$vars" | jq -r '.data.vars.mdResyncPos // "0"')
    size=$(echo   "$vars" | jq -r '.data.vars.mdResyncSize // 0')
    db=$(echo     "$vars" | jq -r '.data.vars.mdResyncDb  // "0"')
    dt=$(echo     "$vars" | jq -r '.data.vars.mdResyncDt  // "0"')

    [ "${size:-0}" -eq 0 ] && { echo "UNKNOWN|0|0|0"; return; }
    pct=$(awk   "BEGIN{printf \"%.1f\", ${pos:-0}/${size}*100}")
    [ "${dt:-0}" -gt 0 ] && speed=$(awk "BEGIN{printf \"%.0f\", ${db:-0}/${dt}}")
    [ "${speed:-0}" -gt 0 ] && eta=$(awk "BEGIN{printf \"%.0f\", (${size}-${pos:-0})/${speed}/60}")
    local status="RUNNING"; [ "${resync:-1}" = "0" ] && status="PAUSED"
    echo "${status}|${pct}|${speed}|${eta}"
  else
    echo "IDLE|0|0|0"
  fi
}

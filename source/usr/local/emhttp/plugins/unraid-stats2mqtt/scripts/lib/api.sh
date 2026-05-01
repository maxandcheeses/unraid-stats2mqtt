#!/bin/bash

declare -A _API_CACHE
declare -A _API_CACHE_TICK

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

get_array_data() {
  _api_cached "array" '{ array { state capacity { kilobytes { free used total } disks { free used total } } parities { name device status temp numErrors type } disks { name device status temp numErrors fsSize fsFree fsUsed type color isSpinning } caches { name device status fsSize fsFree fsUsed } parityCheckStatus { date duration speed status errors progress running paused } } }'
}

get_vars_data() {
  _api_cached "vars" '{ vars { version name sysModel mdNumDisks mdNumDisabled mdNumInvalid mdNumMissing mdColor mdState mdResync mdResyncAction mdResyncPos mdResyncDb mdResyncDt sbSyncErrs flashGuid regState } }'
}

get_shares_data() {
  _api_cached "shares" '{ shares { name free used size comment color } }'
}

get_parity_history_data() {
  _api_cached "parityHistory" '{ parityHistory { date duration speed status errors } }'
}

get_info_data() {
  _api_cached "info" '{ info { os { hostname platform uptime kernel arch } cpu { brand cores threads } } }'
}

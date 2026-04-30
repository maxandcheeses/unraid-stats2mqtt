#!/bin/bash

safe_name()  { echo "$1" | tr ' ' '_' | tr -dc '[:alnum:]_'; }
is_enabled() { [[ "$1" == "onchange" || "$1" == "interval" || "$1" == "both" ]]; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  echo "$s"
}

read_ini_section() {
  local file="$1" section="$2"
  [ ! -f "$file" ] && return
  awk -v sec="$section" '
    $0 == "["sec"]" { in_sec=1; next }
    /^\[/            { in_sec=0 }
    in_sec && /=/    { print }
  ' "$file" 2>/dev/null
}

ini_field() {
  local data="$1" key="$2"
  echo "$data" | grep -E "^${key}=" | head -1 | cut -d= -f2- | tr -d '"'
}

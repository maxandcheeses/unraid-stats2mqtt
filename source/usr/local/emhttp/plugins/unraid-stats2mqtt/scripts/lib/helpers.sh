#!/bin/bash

safe_name() { echo "$1" | tr ' ' '_' | tr -dc '[:alnum:]_'; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  echo "$s"
}

#!/bin/bash
# SOURCE: Local filesystem reads (non-API)

get_update_check_data() {
  local check_file="/tmp/unraidcheck/result.json"
  [ -f "$check_file" ] || return 1
  cat "$check_file"
}

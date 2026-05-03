#!/bin/bash
# SOURCE: Local filesystem reads (non-API)

# Returns the raw JSON from Unraid's update checker (/tmp/unraidcheck/result.json).
# The Unraid GraphQL API has no equivalent — this file is the only source for OS update availability.
# Returns 1 if the file doesn't exist (checker hasn't run yet).
get_update_check_data() {
  local check_file="/tmp/unraidcheck/result.json"
  [ -f "$check_file" ] || return 1
  cat "$check_file"
}

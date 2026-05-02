#!/bin/bash
# SOURCE: Unraid GraphQL API (docker containers)

publish_docker() {
  local expire="${1:-0}" retain="${2:-false}"
  local mode="${DOCKER_SENSOR_MODE:-include}"
  local list="${DOCKER_SENSORS:-}"

  local data; data=$(get_docker_data) || return

  while IFS=$'\t' read -r raw_name state status image auto_start; do
    local name="${raw_name#/}"

    if [ "$mode" = "include" ]; then
      [ -z "$list" ] && continue
      echo ",$list," | grep -qF ",${name}," || continue
    else
      [ -n "$list" ] && echo ",$list," | grep -qF ",${name}," && continue
    fi

    local sn; sn=$(safe_name "$name")
    local uid="docker_${sn}"
    local state_topic="${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_${uid}/state"
    local attr_topic="${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_${uid}/attributes"

    ha_register_binary "$uid" "${name}" "$state_topic" "" "docker" "$expire" "$attr_topic"

    local value="OFF"
    [ "$state" = "RUNNING" ] && value="ON"
    mqtt_publish "$state_topic" "$value" "$retain"

    local attrs
    attrs=$(printf '{"status":"%s","image":"%s","autoStart":%s}' \
      "$(json_escape "$status")" "$(json_escape "$image")" "${auto_start:-false}")
    mqtt_publish "$attr_topic" "$attrs" "$retain"
  done < <(echo "$data" | jq -r '.data.docker.containers[] | [(.names[0] // ""), (.state // ""), (.status // ""), (.image // ""), (.autoStart | tostring)] | @tsv')
}

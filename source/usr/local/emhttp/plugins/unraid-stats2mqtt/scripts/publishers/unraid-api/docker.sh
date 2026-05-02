#!/bin/bash
# SOURCE: Unraid GraphQL API (docker containers)

publish_docker() {
  local expire="${1:-0}" retain="${2:-false}"
  local mode="${DOCKER_SENSOR_MODE:-include}"
  local list="${DOCKER_SENSORS:-}"

  local data; data=$(get_docker_data) || return

  while IFS= read -r container_json; do
    local raw_name state status image image_id auto_start ports_json
    raw_name=$(echo "$container_json"  | jq -r '.names[0] // ""')
    state=$(echo "$container_json"     | jq -r '.state // ""')
    status=$(echo "$container_json"    | jq -r '.status // ""')
    image=$(echo "$container_json"     | jq -r '.image // ""')
    image_id=$(echo "$container_json"  | jq -r '.imageId // ""')
    auto_start=$(echo "$container_json" | jq -r '.autoStart | tostring')
    ports_json=$(echo "$container_json" | jq -c '[.ports[]? | {ip,privatePort,publicPort,type}]')

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

    local raw_id full_id container_id
    raw_id=$(echo "$container_json" | jq -r '.id // ""')
    # API returns <nodeId>:<containerId> — extract just the container portion
    full_id="${raw_id##*:}"
    container_id="${full_id:0:12}"

    local attrs
    attrs=$(printf '{"state":"%s","id":"%s","status":"%s","image":"%s","imageId":"%s","autoStart":%s,"ports":%s}' \
      "$(json_escape "$state")" "$(json_escape "$container_id")" "$(json_escape "$status")" "$(json_escape "$image")" \
      "$(json_escape "$image_id")" "${auto_start:-false}" "${ports_json:-[]}")
    mqtt_publish "$attr_topic" "$attrs" "$retain"
  done < <(echo "$data" | jq -c '.data.docker.containers[]')
}

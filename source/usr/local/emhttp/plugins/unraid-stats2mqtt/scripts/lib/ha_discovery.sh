#!/bin/bash

declare -A _HA_REGISTERED

# Usage: ha_register <uid> <name> <state_topic> <unit> <device_class> <icon> [value_template] [expire_after] [json_attributes_topic]
ha_register() {
  local uid="$1" name="$2" state_topic="$3" unit="$4" dev_class="$5" icon="$6"
  local value_template="${7:-}" expire_after="${8:-0}" json_attributes_topic="${9:-}"
  local config_topic="${HA_DISCOVERY_TOPIC}/sensor/${MQTT_TOPIC}_${uid}/config"
  local cache_key="${uid}_${expire_after}"
  [ "${_HA_REGISTERED[$cache_key]+set}" ] && return

  local device_json
  device_json=$(printf '{"identifiers":["%s"],"name":"%s","manufacturer":"Lime Technology","model":"Unraid Server"}' \
    "$MQTT_DEVICE_ID" "$MQTT_DEVICE_NAME")

  local expire_field="" unit_field="" devclass_field="" vt_field="" jat_field=""
  [ "$expire_after" -gt 0 ] 2>/dev/null && expire_field=$(printf ',"expire_after":%d' "$expire_after")
  [ -n "$unit" ]           && unit_field=$(printf ',"unit_of_measurement":"%s"' "$unit")
  [ -n "$dev_class" ]      && devclass_field=$(printf ',"device_class":"%s"' "$dev_class")
  [ -n "$value_template" ]          && vt_field=$(printf ',"value_template":"%s"' "$value_template")
  [ -n "$json_attributes_topic" ]   && jat_field=$(printf ',"json_attributes_topic":"%s"' "$json_attributes_topic")

  local payload
  payload=$(printf '{"name":"%s","unique_id":"%s_%s","state_topic":"%s","availability_topic":"%s","icon":"mdi:%s"%s%s%s%s%s,"device":%s}' \
    "$name" "$MQTT_DEVICE_ID" "$uid" "$state_topic" "$AVAILABILITY_TOPIC" "$icon" \
    "$unit_field" "$devclass_field" "$vt_field" "$expire_field" "$jat_field" "$device_json")

  log "Discovery: $config_topic"
  mqtt_publish "$config_topic" "$payload" true
  _HA_REGISTERED[$cache_key]=1
}

# Usage: ha_register_binary <uid> <name> <state_topic> <device_class> <icon> [expire_after] [json_attributes_topic]
ha_register_binary() {
  local uid="$1" name="$2" state_topic="$3" dev_class="$4" icon="$5"
  local expire_after="${6:-0}" json_attributes_topic="${7:-}"
  local config_topic="${HA_DISCOVERY_TOPIC}/binary_sensor/${MQTT_TOPIC}_${uid}/config"
  local cache_key="${uid}_${expire_after}"
  [ "${_HA_REGISTERED[$cache_key]+set}" ] && return

  local device_json
  device_json=$(printf '{"identifiers":["%s"],"name":"%s","manufacturer":"Lime Technology","model":"Unraid Server"}' \
    "$MQTT_DEVICE_ID" "$MQTT_DEVICE_NAME")

  local expire_field="" devclass_field="" jat_field=""
  [ "$expire_after" -gt 0 ] 2>/dev/null && expire_field=$(printf ',"expire_after":%d' "$expire_after")
  [ -n "$dev_class" ]                    && devclass_field=$(printf ',"device_class":"%s"' "$dev_class")
  [ -n "$json_attributes_topic" ]        && jat_field=$(printf ',"json_attributes_topic":"%s"' "$json_attributes_topic")

  local payload
  payload=$(printf '{"name":"%s","unique_id":"%s_%s","state_topic":"%s","availability_topic":"%s","icon":"mdi:%s","payload_on":"ON","payload_off":"OFF"%s%s%s,"device":%s}' \
    "$name" "$MQTT_DEVICE_ID" "$uid" "$state_topic" "$AVAILABILITY_TOPIC" "$icon" \
    "$devclass_field" "$expire_field" "$jat_field" "$device_json")

  log "Discovery: $config_topic"
  mqtt_publish "$config_topic" "$payload" true
  _HA_REGISTERED[$cache_key]=1
}

ha_unregister() {
  local uid="$1"
  local config_topic="${HA_DISCOVERY_TOPIC}/sensor/${MQTT_TOPIC}_${uid}/config"
  local cache_key="${uid}_unregister"
  [ "${_HA_REGISTERED[$cache_key]+set}" ] && return
  log "Discovery remove: $config_topic"
  mqtt_publish "$config_topic" "" true
  _HA_REGISTERED[$cache_key]=1
}

resolve_expire() {
  local expire="$1" interval="${2:-0}"
  [ "${expire:-0}" -le 0 ] && echo 0 && return
  local base=$expire
  [ "$interval" -gt "$base" ] && base=$interval
  echo $(( base + 1 ))
}

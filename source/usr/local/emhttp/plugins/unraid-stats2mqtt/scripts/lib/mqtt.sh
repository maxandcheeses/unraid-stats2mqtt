#!/bin/bash

mqtt_publish() {
  local topic="$1" payload="$2" retain="${3:-true}"
  local _mqtt_err _mqtt_rc
  build_mqtt_args
  if [ "$retain" = "true" ]; then
    _mqtt_err=$(mosquitto_pub "${MQTT_ARGS[@]}" -r -t "$topic" -m "$payload" 2>&1)
  else
    _mqtt_err=$(mosquitto_pub "${MQTT_ARGS[@]}" -t "$topic" -m "$payload" 2>&1)
  fi
  _mqtt_rc=$?
  if [ $_mqtt_rc -ne 0 ]; then
    local _broker="${MQTT_PROTOCOL:-mqtt}://${MQTT_HOST}:${MQTT_PORT}"
    log "ERROR: MQTT publish failed (rc=${_mqtt_rc}) broker=${_broker} topic=${topic}${_mqtt_err:+ — ${_mqtt_err}}"
  fi
  return $_mqtt_rc
}

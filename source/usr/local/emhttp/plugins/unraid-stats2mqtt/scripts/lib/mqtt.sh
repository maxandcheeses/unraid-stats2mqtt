#!/bin/bash

mqtt_publish() {
  local topic="$1" payload="$2" retain="${3:-true}"
  build_mqtt_args
  if [ "$retain" = "true" ]; then
    mosquitto_pub "${MQTT_ARGS[@]}" -r -t "$topic" -m "$payload" 2>>"$LOG_FILE"
  else
    mosquitto_pub "${MQTT_ARGS[@]}" -t "$topic" -m "$payload" 2>>"$LOG_FILE"
  fi
}

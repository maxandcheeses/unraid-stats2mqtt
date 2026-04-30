#!/bin/bash
# SOURCE: disks.ini + /var/local/emhttp/smart/* + /proc/diskstats
# Fields (per disk section): device, status, temp, color, numErrors,
#                             fsSize, fsFree, fsUsed + all other raw fields
# + /var/local/emhttp/smart/* (SMART health, power hours, reallocated sectors)
# + /proc/diskstats (read/write speeds)

_unregister_disk_sensors() {
  local sn; sn=$(safe_name "$1")
  ha_unregister "${sn}_state"
  ha_unregister "${sn}_temp"
  ha_unregister "${sn}"
  ha_unregister "${sn}_errors"
  ha_unregister "${sn}_smart_health"
  ha_unregister "${sn}_reallocated"
  ha_unregister "${sn}_pending_sectors"
  ha_unregister "${sn}_offline_uncorrectable"
}

publish_disk_temps() {
  local expire="${1:-0}" retain="${2:-true}"
  local disk_cfg="/var/local/emhttp/disks.ini"
  [ ! -f "$disk_cfg" ] && return

  local cur_disk="" cur_dev="" cur_temp="" cur_status=""

  _flush_temp() {
    [ -z "$cur_disk" ] || [ -z "$cur_dev" ] || [ -z "$cur_temp" ] && return
    [[ "$cur_temp" == "*" ]] && return
    [[ "$cur_status" == DISK_NP* ]] && return
    local sn; sn=$(safe_name "$cur_disk")
    local topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${sn}_temp/state"
    ha_register "${sn}_temp" "${cur_disk} Temperature" "$topic" "°C" "temperature" "thermometer" "" "$expire"
    mqtt_publish "$topic" "$cur_temp" "$retain"
  }

  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      _flush_temp
      cur_disk="${BASH_REMATCH[1]//\"/}"; cur_dev=""; cur_temp=""; cur_status=""
    fi
    [[ "$line" =~ ^device=(.+) ]] && cur_dev="${BASH_REMATCH[1]//\"/}"
    [[ "$line" =~ ^temp=(.+) ]]   && cur_temp="${BASH_REMATCH[1]//\"/}"
    [[ "$line" =~ ^status=(.+) ]] && cur_status="${BASH_REMATCH[1]//\"/}"
  done < "$disk_cfg"
  _flush_temp
}

publish_disk_states() {
  local expire="${1:-0}" retain="${2:-true}"
  local disk_cfg="/var/local/emhttp/disks.ini"
  [ ! -f "$disk_cfg" ] && return

  local cur_disk="" cur_dev="" cur_status=""

  _flush_state() {
    [ -z "$cur_disk" ] || [ -z "$cur_status" ] && return
    [ -z "$cur_dev" ] && [[ "$cur_status" != DISK_NP* ]] && return

    local sn; sn=$(safe_name "$cur_disk")
    local state
    case "$cur_status" in
      DISK_OK)   state="ACTIVE" ;;
      DISK_DSBL) state="DISABLED" ;;
      DISK_NP*)
        _unregister_disk_sensors "$cur_disk"
        return
        ;;
      *)
        if hdparm -C "/dev/$cur_dev" 2>/dev/null | grep -q "standby"; then
          state="STANDBY"
        else
          state="ACTIVE"
        fi
        ;;
    esac
    local topic="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${sn}_state/state"
    ha_register "${sn}_state" "${cur_disk} State" "$topic" "" "" "harddisk" "" "$expire"
    mqtt_publish "$topic" "$state" "$retain"
  }

  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      _flush_state
      cur_disk="${BASH_REMATCH[1]//\"/}"; cur_dev=""; cur_status=""
    fi
    [[ "$line" =~ ^device=(.+) ]] && cur_dev="${BASH_REMATCH[1]//\"/}"
    [[ "$line" =~ ^status=(.+) ]] && cur_status="${BASH_REMATCH[1]//\"/}"
  done < "$disk_cfg"
  _flush_state
}

publish_disk_usage() {
  local expire="${1:-0}" retain="${2:-true}"
  local disk_cfg="/var/local/emhttp/disks.ini"
  [ ! -f "$disk_cfg" ] && return

  local cur_disk="" cur_status="" cur_fs_size="" cur_fs_free="" cur_fs_used=""
  local -A cur_fields

  _flush_usage() {
    [ -z "$cur_disk" ] && return
    [[ "$cur_status" == DISK_NP* ]] && return
    [ "${cur_fs_size:-0}" -le 0 ] 2>/dev/null && return
    local sn; sn=$(safe_name "$cur_disk")
    local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${sn}"

    local used_kb="${cur_fs_used}"
    [ "${used_kb:-0}" -le 0 ] 2>/dev/null && [ "${cur_fs_free:-0}" -gt 0 ] 2>/dev/null && \
      used_kb=$(( cur_fs_size - cur_fs_free ))

    local used_pct; used_pct=$(awk "BEGIN{printf \"%.1f\", ($cur_fs_size-${cur_fs_free:-0})/$cur_fs_size*100}")
    local size_gb;  size_gb=$(awk  "BEGIN{printf \"%.2f\", $cur_fs_size/1048576}")
    local free_gb;  free_gb=$(awk  "BEGIN{printf \"%.2f\", ${cur_fs_free:-0}/1048576}")
    local used_gb;  used_gb=$(awk  "BEGIN{printf \"%.2f\", ${used_kb:-0}/1048576}")

    local attr_json="{\"size_gb\":$size_gb,\"free_gb\":$free_gb,\"used_gb\":$used_gb"
    local k
    for k in "${!cur_fields[@]}"; do
      attr_json+=",\"$(json_escape "$k")\":\"$(json_escape "${cur_fields[$k]}")\""
    done
    local rs_file="$STATE_DIR/${sn}_read_speed.val"
    local ws_file="$STATE_DIR/${sn}_write_speed.val"
    [ -f "$rs_file" ] && attr_json+=",\"read_speed\":\"$(cat "$rs_file")\""
    [ -f "$ws_file" ] && attr_json+=",\"write_speed\":\"$(cat "$ws_file")\""
    attr_json+="}"

    local attr_topic="${base}/attributes"
    ha_register "${sn}" "${cur_disk} Usage" "${base}/state" "%" "" "harddisk" "" "$expire" "$attr_topic"
    mqtt_publish "${base}/state" "$used_pct" "$retain"
    mqtt_publish "$attr_topic" "$attr_json" "$retain"
  }

  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      _flush_usage
      cur_disk="${BASH_REMATCH[1]//\"/}"; cur_status=""; cur_fs_size=""; cur_fs_free=""; cur_fs_used=""; cur_fields=()
    fi
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]//\"/}"
      cur_fields[$k]="$v"
      case "$k" in
        status) cur_status="$v" ;;
        fsSize)  cur_fs_size="$v" ;;
        fsFree)  cur_fs_free="$v" ;;
        fsUsed)  cur_fs_used="$v" ;;
      esac
    fi
  done < "$disk_cfg"
  _flush_usage
}

publish_disk_errors() {
  local expire="${1:-0}" retain="${2:-true}"
  local disk_cfg="/var/local/emhttp/disks.ini"
  [ ! -f "$disk_cfg" ] && return

  local cur_disk="" cur_status="" cur_errors=""

  _flush_errors() {
    [ -z "$cur_disk" ] && return
    [[ "$cur_status" == DISK_NP* ]] && return
    local sn; sn=$(safe_name "$cur_disk")
    local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${sn}"
    [ -n "$cur_errors" ] && {
      ha_register "${sn}_errors" "${cur_disk} Errors" "${base}_errors/state" "" "" "alert-circle" "" "$expire"
      mqtt_publish "${base}_errors/state" "$cur_errors" "$retain"
    }
  }

  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      _flush_errors
      cur_disk="${BASH_REMATCH[1]//\"/}"; cur_status=""; cur_errors=""
    fi
    [[ "$line" =~ ^status=(.+) ]]    && cur_status="${BASH_REMATCH[1]//\"/}"
    [[ "$line" =~ ^numErrors=(.+) ]] && cur_errors="${BASH_REMATCH[1]//\"/}"
  done < "$disk_cfg"
  _flush_errors
}


publish_smart() {
  local expire="${1:-0}" retain="${2:-true}"
  local disk_cfg="/var/local/emhttp/disks.ini"
  [ ! -f "$disk_cfg" ] && return

  local cur_disk="" cur_dev="" cur_status=""

  _flush_smart() {
    [ -z "$cur_disk" ] || [ -z "$cur_dev" ] && return
    [[ "$cur_status" == DISK_NP* ]] && return
    [ ! -b "/dev/$cur_dev" ] && return
    local sn; sn=$(safe_name "$cur_disk")
    local base="${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_${sn}"

    local smart_file="/var/local/emhttp/smart/${cur_disk}"
    local smart_attrs; smart_attrs=$(cat "$smart_file" 2>/dev/null)

    local smart_health smart_health_raw
    # SATA: grep overall-health line; NVMe: derive from Critical Warning (0x00 = OK)
    smart_health_raw=$(echo "$smart_attrs" | grep -iE "overall" | grep -oP '(PASSED|FAILED)')
    if [ -z "$smart_health_raw" ]; then
      local crit_warn; crit_warn=$(echo "$smart_attrs" | awk '/Critical Warning:/{print $NF}')
      [ -n "$crit_warn" ] && { [ "$crit_warn" = "0x00" ] && smart_health_raw="OK" || smart_health_raw="FAILED"; }
    fi
    smart_health="${smart_health_raw^^}"; smart_health="${smart_health:-UNKNOWN}"

    # SATA attributes (column 10 = RAW_VALUE); NVMe uses "Label: value" format
    local power_hours;    power_hours=$(echo    "$smart_attrs" | awk '/Power_On_Hours/{print $10}    /Power On Hours:/{print $NF}')
    local power_cycles;   power_cycles=$(echo   "$smart_attrs" | awk '/Power_Cycle_Count/{print $10} /Power Cycles:/{print $NF}')
    local reallocated;    reallocated=$(echo     "$smart_attrs" | awk '/Reallocated_Sector_Ct/{print $10}')
    local pending;        pending=$(echo         "$smart_attrs" | awk '/Current_Pending_Sector/{print $10}')
    local uncorrectable;  uncorrectable=$(echo   "$smart_attrs" | awk '/Offline_Uncorrectable/{print $10}')
    local crc_errors;     crc_errors=$(echo      "$smart_attrs" | awk '/UDMA_CRC_Error_Count/{print $10}')
    local load_cycles;    load_cycles=$(echo     "$smart_attrs" | awk '/Load_Cycle_Count/{print $10}')
    # NVMe-specific
    local nvme_wear;      nvme_wear=$(echo       "$smart_attrs" | awk '/Percentage Used:/{gsub(/%/,"",$NF); print $NF}')
    local nvme_spare;     nvme_spare=$(echo      "$smart_attrs" | awk '/Available Spare:/{gsub(/%/,"",$NF); print $NF}' | head -1)
    local nvme_shutdowns; nvme_shutdowns=$(echo  "$smart_attrs" | awk '/Unsafe Shutdowns:/{print $NF}')
    local nvme_media;     nvme_media=$(echo      "$smart_attrs" | awk '/Media and Data Integrity Errors:/{print $NF}')

    # _smart_health: attributes = overall_health, crc_errors, nvme_unsafe_shutdowns, nvme_media_errors
    local health_attrs="{}"
    local health_attr_parts=()
    health_attr_parts+=("\"overall_health\":\"${smart_health_raw:-UNKNOWN}\"")
    [ -n "$crc_errors" ]    && health_attr_parts+=("\"crc_errors\":$crc_errors")
    [ -n "$nvme_shutdowns" ] && health_attr_parts+=("\"unsafe_shutdowns\":$nvme_shutdowns")
    [ -n "$nvme_media" ]    && health_attr_parts+=("\"media_errors\":$nvme_media")
    [ -n "$nvme_wear" ]     && health_attr_parts+=("\"percentage_used\":$nvme_wear")
    [ -n "$nvme_spare" ]    && health_attr_parts+=("\"available_spare\":$nvme_spare")
    [ -n "$power_hours" ]   && health_attr_parts+=("\"power_on_hours\":$power_hours")
    [ -n "$power_cycles" ]  && health_attr_parts+=("\"power_cycles\":$power_cycles")
    [ -n "$load_cycles" ]   && health_attr_parts+=("\"load_cycles\":$load_cycles")
    if [ "${#health_attr_parts[@]}" -gt 0 ]; then
      local IFS=','; health_attrs="{${health_attr_parts[*]}}"
    fi
    ha_register "${sn}_smart_health" "${cur_disk} SMART Health" "${base}_smart_health/state" "" "" "shield-check" "" "$expire" "${base}_smart_health/attributes"
    mqtt_publish "${base}_smart_health/state" "$smart_health" "$retain"
    mqtt_publish "${base}_smart_health/attributes" "$health_attrs" "$retain"

    [ -n "$reallocated" ] && {
      ha_register "${sn}_reallocated" "${cur_disk} Reallocated Sectors" "${base}_reallocated/state" "" "" "alert-circle" "" "$expire"
      mqtt_publish "${base}_reallocated/state" "$reallocated" "$retain"
    }
    [ -n "$pending" ] && {
      ha_register "${sn}_pending_sectors" "${cur_disk} Pending Sectors" "${base}_pending_sectors/state" "" "" "alert-circle-outline" "" "$expire"
      mqtt_publish "${base}_pending_sectors/state" "$pending" "$retain"
    }
    [ -n "$uncorrectable" ] && {
      ha_register "${sn}_offline_uncorrectable" "${cur_disk} Offline Uncorrectable" "${base}_offline_uncorrectable/state" "" "" "close-octagon-outline" "" "$expire"
      mqtt_publish "${base}_offline_uncorrectable/state" "$uncorrectable" "$retain"
    }
  }

  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
      _flush_smart
      cur_disk="${BASH_REMATCH[1]//\"/}"; cur_dev=""; cur_status=""
    fi
    [[ "$line" =~ ^device=(.+) ]] && cur_dev="${BASH_REMATCH[1]//\"/}"
    [[ "$line" =~ ^status=(.+) ]] && cur_status="${BASH_REMATCH[1]//\"/}"
  done < "$disk_cfg"
  _flush_smart
}

declare -A PREV_READ_BYTES PREV_WRITE_BYTES PREV_READ_TIME

publish_rw_speeds() {
  local expire="${1:-0}"
  local disk_cfg="/var/local/emhttp/disks.ini"
  [ ! -f "$disk_cfg" ] && return

  local devs=()
  while IFS= read -r line; do
    [[ "$line" =~ ^device=(.+) ]] && devs+=("${BASH_REMATCH[1]//\"/}")
  done < "$disk_cfg"

  local now; now=$(date +%s)

  for dev in "${devs[@]}"; do
    [ ! -b "/dev/$dev" ] && continue
    local stats; stats=$(awk -v d=" $dev " '$0~d{print;exit}' /proc/diskstats 2>/dev/null)
    [ -z "$stats" ] && continue

    local read_bytes write_bytes
    read_bytes=$(( $(echo "$stats" | awk '{print $6}') * 512 ))
    write_bytes=$(( $(echo "$stats" | awk '{print $10}') * 512 ))

    if [ -n "${PREV_READ_BYTES[$dev]+x}" ]; then
      local elapsed=$(( now - PREV_READ_TIME[$dev] ))
      [ "$elapsed" -le 0 ] && elapsed=1

      local read_speed write_speed
      read_speed=$(( (read_bytes - PREV_READ_BYTES[$dev]) / elapsed / 1024 ))
      write_speed=$(( (write_bytes - PREV_WRITE_BYTES[$dev]) / elapsed / 1024 ))

      local disk_label
      disk_label=$(awk -v d="$dev" '/^\[/{lbl=$0} /^device=/{if($0~d)print lbl}' \
        "$disk_cfg" | tr -d '[]"')
      [ -z "$disk_label" ] && disk_label="$dev"
      local sn; sn=$(safe_name "$disk_label")

      echo "$read_speed"  > "$STATE_DIR/${sn}_read_speed.val"
      echo "$write_speed" > "$STATE_DIR/${sn}_write_speed.val"
    fi

    PREV_READ_BYTES[$dev]="$read_bytes"
    PREV_WRITE_BYTES[$dev]="$write_bytes"
    PREV_READ_TIME[$dev]="$now"
  done
}

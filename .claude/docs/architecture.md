# Architecture: unraid-stats2mqtt

## Overview

A bash daemon that runs on Unraid, reads system state from Unraid's emhttp `.ini` files and kernel pseudo-files, and publishes metrics to MQTT in Home Assistant auto-discovery format.

## Repository Layout

```
source/                              ← everything here gets tarred into the .txz package
  etc/rc.d/rc.unraid-stats2mqtt    ← init script: start/stop/restart/status
  usr/local/emhttp/plugins/unraid-stats2mqtt/
    scripts/
      mqtt_monitor.sh                ← entry point (sources all lib/ and metrics/)
      lib/
        config.sh                    ← load_config, build_mqtt_args
        logging.sh                   ← log (with 1 MB rotation)
        mqtt.sh                      ← mqtt_publish (wraps mosquitto_pub)
        ha_discovery.sh              ← ha_register, ha_unregister, resolve_expire
        helpers.sh                   ← safe_name, is_enabled, json_escape, read_ini_section, ini_field
        loop.sh                      ← state_changed, should_publish_interval, _publish_metric
      metrics/
        var_ini.sh                   ← array status/summary, cache, parity, rebuild, system info
        disks_ini.sh                 ← disk temps/states/usage/errors/JSON, SMART, R/W speeds
        monitor_ini.sh               ← array errors, parity history, flash state, docker usage, per-disk usage/alert
        network.sh                   ← per-interface RX/TX speeds from /proc/net/dev
        shares_ini.sh                ← per-share JSON from shares.ini
    images/
    include/exec.php                 ← PHP shim for UI-triggered script calls
    unraid-stats2mqtt.page         ← Unraid plugin UI page
plugin/
  unraid-stats2mqtt.plg            ← Unraid plugin manifest (XML)
build.sh                             ← bumps BUILD, tars source/ into dist/*.txz, patches .plg MD5
BUILD                                ← auto-incremented build counter
dist/                                ← build output (gitignored)
```

## Data Flow

```
Unraid emhttp .ini files  →  metrics/*.sh  →  mqtt_publish  →  MQTT broker  →  Home Assistant
  /var/local/emhttp/
    var.ini
    disks.ini
    monitor.ini
    shares.ini
  /proc/net/dev
  /proc/diskstats
  smartctl
```

## Metric Sources

| File / Source          | Publisher           | Key metrics |
|------------------------|---------------------|-------------|
| `var.ini`              | `metrics/var_ini.sh`     | array state, disk counts, capacity, cache pool, parity/rebuild progress, Unraid version |
| `disks.ini`            | `metrics/disks_ini.sh`   | per-disk temp, state, filesystem usage, errors, health color, SMART, R/W speeds, full JSON |
| `monitor.ini`          | `metrics/monitor_ini.sh` | array errors, parity history, flash state, Docker vdisk %, per-disk usage %, per-disk alert color |
| `/proc/net/dev`        | `metrics/network.sh`     | per-interface RX/TX KB/s |
| `shares.ini`           | `metrics/shares_ini.sh`  | per-share JSON blob |

## Publish Modes

Each metric group is independently configured via `config.cfg`:

- `PUBLISH_<METRIC>` — `interval` | `onchange` | `both` | (empty = disabled)
- `INTERVAL_<METRIC>` — seconds between interval publishes
- `EXPIRE_<METRIC>` — HA `expire_after` seconds (0 = no expiry)

The `_publish_metric` helper in `lib/loop.sh` handles the mode logic:
- **onchange**: computes a snapshot hash, only publishes when it changes
- **interval**: publishes every N ticks (tick = 10 s)
- **both**: onchange fires immediately on change; interval fires if onchange didn't already publish this tick

Speed metrics (R/W speeds, network) are stateful — they store previous byte counts in associative arrays and diff on each tick.

## Home Assistant Discovery

`ha_register` (in `lib/ha_discovery.sh`) publishes to `homeassistant/sensor/<device_id>_<uid>/config` on first call per unique `uid+expire_after`. Results are cached in `_HA_REGISTERED` for the process lifetime. When HA comes back online (detected via `mosquitto_sub` watching `homeassistant/status`), `_HA_REGISTERED` is cleared and all enabled metrics re-register.

## Config

Config file: `/boot/config/plugins/unraid-stats2mqtt/config.cfg`  
Key variables: `MQTT_HOST`, `MQTT_PORT`, `MQTT_PROTOCOL` (mqtt/mqtts/wss), `MQTT_USER`, `MQTT_PASS`, `MQTT_DEVICE_ID`, `MQTT_DEVICE_NAME`, `MQTT_BASE_TOPIC`, `MQTT_TOPIC`.

TLS: set `MQTT_PROTOCOL=mqtts`, `MQTT_CA_CERT`, optionally `MQTT_CLIENT_CERT`/`MQTT_CLIENT_KEY`, `MQTT_TLS_INSECURE=true`.

## Runtime State

| Path | Purpose |
|------|---------|
| `/tmp/unraid-stats2mqtt/*.state` | Last-seen snapshot hashes for onchange detection |
| `/tmp/unraid-stats2mqtt/*.tick`  | Last tick each interval metric published |
| `/var/run/unraid-stats2mqtt.pid` | Daemon PID |
| `/var/log/unraid-stats2mqtt.log` | Log (rotated at 1 MB to `.log.1`) |

## Build & Packaging

```bash
./build.sh            # increments BUILD, creates dist/<plugin>-<version>-x86_64-1.txz + .plg
```

The `.plg` file references the GitHub release URL for the `.txz`. After building, upload both files to a GitHub release and install on Unraid via Plugins > Install Plugin.

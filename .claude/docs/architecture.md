# Architecture: unraid-stats2mqtt

## Overview

A bash daemon that runs on Unraid, reads system state via the **Unraid GraphQL API**, and publishes metrics to MQTT in Home Assistant auto-discovery format.

## Repository Layout

```
source/                              ← everything here gets tarred into the .txz package
  etc/rc.d/rc.unraid-stats2mqtt    ← init script: start/stop/restart/status
  usr/local/emhttp/plugins/unraid-stats2mqtt/
    scripts/
      mqtt_monitor.sh                ← entry point (sources all lib/, collectors/, publishers/)
      lib/
        config.sh                    ← load_config, build_mqtt_args
        logging.sh                   ← log (with 1 MB rotation)
        mqtt.sh                      ← mqtt_publish (wraps mosquitto_pub)
        ha_discovery.sh              ← ha_register, ha_unregister, resolve_expire
        helpers.sh                   ← safe_name, json_escape, get_update_check_data
        loop.sh                      ← should_publish_interval, _publish_metric
      collectors/
        unraid-api.sh                ← GraphQL query helpers + per-tick in-memory cache
        cli.sh                       ← helpers that call local CLI tools (jq, date)
      publishers/
        unraid-api/
          var.sh                     ← array status/summary, cache, parity, rebuild, system info, update available
          disks.sh                   ← disk temps/states/usage/errors per array disk
          monitor.sh                 ← array sync errors, parity history
          system.sh                  ← system uptime
          network.sh                 ← per-interface status + attributes
          shares.sh                  ← per-share usage + attributes
          docker.sh                  ← per-container binary sensor
          vms.sh                     ← per-VM binary sensor
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
Unraid GraphQL API  →  collectors/unraid-api.sh  →  publishers/**/*.sh  →  mqtt_publish  →  MQTT broker  →  Home Assistant
  POST /graphql
    { array { ... } }
    { vars { ... } }
    { info { ... } }
    { shares { ... } }
    { docker { ... } }
    { vms { ... } }
    { parityHistory { ... } }
```

## Metric Sources

| API Query | Publisher | Key metrics |
|---|---|---|
| `array` | `publishers/unraid-api/var.sh` | array state, disk counts, capacity, cache pool |
| `vars` | `publishers/unraid-api/var.sh` | parity/rebuild progress, Unraid version, sync errors |
| `vars` + `info` | `publishers/unraid-api/var.sh` | system identification + update available |
| `info` | `publishers/unraid-api/system.sh` | system uptime |
| `array` | `publishers/unraid-api/disks.sh` | per-disk temp, state, filesystem usage, errors |
| `vars` + `parityHistory` | `publishers/unraid-api/monitor.sh` | array sync errors, parity history |
| `info.networkInterfaces` | `publishers/unraid-api/network.sh` | per-interface status (up/down) + IP/MAC/gateway attributes |
| `shares` | `publishers/unraid-api/shares.sh` | per-share usage + attributes |
| `docker.containers` | `publishers/unraid-api/docker.sh` | per-container binary sensor |
| `vms.domain` | `publishers/unraid-api/vms.sh` | per-VM binary sensor |

## API Caching

`collectors/unraid-api.sh` provides `_api_cached <key> <query>` which wraps `graphql_query` with a per-tick in-memory cache. Multiple publishers sharing the same query (e.g. `vars`) make only one HTTP request per tick.

## Publish Loop

`mqtt_monitor.sh` runs a 10-second tick loop (`TICK` increments by 10 each iteration). On `TICK=0` (daemon start), all enabled metrics publish immediately. Thereafter `_publish_metric` in `lib/loop.sh` fires each publisher when `TICK - last_tick >= interval`.

Config is reloaded from disk on every tick, so live config changes take effect without a restart.

## Publish Settings

Each metric group is independently configured via `config.cfg`:

- `INTERVAL_<METRIC>` — seconds between publishes; `0` disables the metric
- `EXPIRE_<METRIC>` — HA `expire_after` seconds (`0` = no expiry, auto-scaled from interval if unset)
- `RETAIN_<METRIC>` — whether MQTT messages are retained (`true` / `false`)

## Home Assistant Discovery

`ha_register` (in `lib/ha_discovery.sh`) publishes to `<ha_discovery_topic>/sensor/<device_id>_<uid>/config` on first call per unique `uid+expire_after`. Results are cached in `_HA_REGISTERED` for the process lifetime. When HA comes back online (detected via `mosquitto_sub` watching the HA status topic), `_HA_REGISTERED` is cleared and all enabled metrics re-register on the next tick.

## Config

Config file: `/boot/config/plugins/unraid-stats2mqtt/config.cfg`  
Key variables: `UNRAID_API_KEY`, `UNRAID_API_HOST`, `MQTT_HOST`, `MQTT_PORT`, `MQTT_PROTOCOL` (mqtt/mqtts/ws/wss), `MQTT_USER`, `MQTT_PASS`, `MQTT_DEVICE_ID`, `MQTT_DEVICE_NAME`, `MQTT_BASE_TOPIC`.

TLS: set `MQTT_PROTOCOL=mqtts`, `MQTT_CA_CERT`, optionally `MQTT_CLIENT_CERT`/`MQTT_CLIENT_KEY`, `MQTT_TLS_INSECURE=true`.

## Runtime State

| Path | Purpose |
|------|---------|
| `/tmp/unraid-stats2mqtt/*.tick`  | Last tick each interval metric published |
| `/var/run/unraid-stats2mqtt.pid` | Daemon PID |
| `/var/log/unraid-stats2mqtt.log` | Log (rotated at 1 MB to `.log.1`) |

## Build & Packaging

```bash
./build.sh            # increments BUILD, creates dist/<plugin>-<version>-x86_64-1.txz + .plg
```

The `.plg` file references the GitHub release URL for the `.txz`. After building, upload both files to a GitHub release and install on Unraid via **Plugins → Install Plugin**.

# unraid-stats2mqtt — Claude Instructions

## Project Overview

A bash daemon that runs on Unraid and publishes system metrics to an MQTT broker in Home Assistant auto-discovery format. See `.claude/docs/architecture.md` for the full technical reference.

## Repository Layout

```
source/                              ← tarballed into the .txz plugin package
  etc/rc.d/rc.unraid-stats2mqtt    ← init script
  usr/local/emhttp/plugins/unraid-stats2mqtt/
    scripts/
      mqtt_monitor.sh                ← entry point (sources lib/ and metrics/)
      lib/                           ← shared utilities (config, logging, mqtt, ha, helpers, loop)
      metrics/                       ← one file per data source
    include/exec.php                 ← PHP shim for UI-triggered script calls
    unraid-stats2mqtt.page         ← Unraid plugin UI page
plugin/unraid-stats2mqtt.plg       ← Unraid plugin manifest
build.sh                             ← packages source/ into dist/*.txz
BUILD                                ← auto-incremented build counter
```

## Feature Planning Workflow

All non-trivial features must have a spec before implementation begins. Use the `planner` sub-agent to create and manage specs.

Spec lifecycle:
- `.claude/docs/specs/planned/` — approved, not started
- `.claude/docs/specs/in-progress/` — actively being worked on
- `.claude/docs/specs/done/` — shipped

Before starting work on a feature, move its spec to `in-progress/`. When complete, move it to `done/`.

## Building

```bash
./build.sh
```

Outputs `dist/<plugin>-<version>-x86_64-1.txz` and an updated `.plg`. Upload both to a GitHub release.

## Testing on Unraid

```bash
# Manual test publish
/usr/local/emhttp/plugins/unraid-stats2mqtt/scripts/mqtt_monitor.sh test

# Connection check
/usr/local/emhttp/plugins/unraid-stats2mqtt/scripts/mqtt_monitor.sh check_connection
```

## Code Conventions

- All metric publishers follow the signature: `publish_<metric>() { local expire="${1:-0}"; ... }`
- Use `ha_register` before every `mqtt_publish` for state topics
- Disk names are sanitized with `safe_name` before use in topic paths or sensor UIDs
- Speed metrics (R/W, network) are stateful — they diff byte counts across ticks using module-level `declare -A` maps
- The main loop ticks every 10 seconds; `TICK` is the cumulative second count
- Config is re-loaded on every tick so live config changes take effect without restart

## Key Files

| File | Purpose |
|------|---------|
| `scripts/lib/config.sh` | `load_config`, `build_mqtt_args` |
| `scripts/lib/ha_discovery.sh` | `ha_register`, `ha_unregister`, `resolve_expire` |
| `scripts/lib/loop.sh` | `_publish_metric`, `state_changed`, `should_publish_interval` |
| `scripts/metrics/var_ini.sh` | Array, cache, parity, rebuild, version |
| `scripts/metrics/disks_ini.sh` | Per-disk sensors + SMART + R/W speeds |
| `scripts/metrics/monitor_ini.sh` | monitor.ini aggregates |
| `scripts/metrics/network.sh` | Network interface speeds |
| `scripts/metrics/shares_ini.sh` | Share JSON sensors |

## Constraints

- Target: Unraid (Slackware-based Linux). Only standard tools available: bash, awk, grep, sed, mosquitto_pub/sub, smartctl, hdparm.
- No external bash libraries or package manager installs.
- The entire `source/` tree is shipped verbatim — no build step transforms it.
- Plugin runs as root on Unraid.

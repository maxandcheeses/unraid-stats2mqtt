# VM and Docker Container Metrics

## Status
planned

## Summary
Add per-VM and per-Docker-container binary sensors to unraid-stats2mqtt. Each Docker container and each VM gets one HA binary sensor whose state reflects whether the workload is currently running. Attributes carry identifying metadata. All data is sourced from the Unraid GraphQL API using the confirmed query shapes from Unraid 7.2.5.

## Goals
- Publish one HA binary sensor per Docker container: ON when `state` is `running`, OFF otherwise; attributes include `status`, `image`, `autoStart`
- Publish one HA binary sensor per VM: ON when `state` is `running`, OFF otherwise; attributes include `state` (raw string) and `uuid`
- Guard against the "VMs are not available" API error so a VM-less system does not crash the daemon
- Follow the existing `_publish_metric` / `ha_register` / `_api_cached` pattern exactly
- Add two new collector files: `scripts/collectors/docker.sh` and `scripts/collectors/vms.sh`
- Add `get_docker_data` and `get_vms_data` functions using `_api_cached` in `scripts/collectors/unraid-api.sh` (or equivalent api helper file)
- Wire both metrics into the main loop in `mqtt_monitor.sh` and the HA-came-online re-publish block
- Add corresponding config knobs and UI settings

## Non-goals
- CPU usage, memory usage, network stats, or any other resource consumption metrics per container or VM (not exposed by the API)
- Start/stop/restart controls (mutations are out of scope)
- `onchange` publish mode (interval-only, consistent with existing API-backed metrics)
- Allowlist filtering (no `VM_ALLOWLIST` or `DOCKER_ALLOWLIST` — all containers and all VMs are always published)
- Any data source other than the Unraid GraphQL API

## Design

### GraphQL queries

The confirmed query shapes for Unraid 7.2.5 are:

**Docker:** `{ docker { containers { id names state status image autoStart } } }`

The `docker` top-level field returns a `Docker` type whose only valid field is `containers`. Each element is a `DockerContainer` with fields: `id`, `names`, `state`, `status`, `image`, `imageId`, `autoStart`, `ports { ip privatePort publicPort type }`. The query above requests only the fields needed for publishing; `ports` and `imageId` are omitted.

**VMs:** `{ vms { domain { id uuid name state } } }`

The `vms` top-level field returns a `Vms` type whose only valid field is `domain`. Each element is a `VmDomain` with confirmed fields: `id`, `uuid`, `name`, `state`. No resource or hardware fields exist on this type. When VMs are not running (or not configured), the API returns an error payload with message "VMs are not available" rather than an empty array.

### Collector: get_docker_data

`get_docker_data` is added to the existing unraid-api collector file. It calls `_api_cached` with the Docker query above. The result is cached for the duration of the tick. Returns the raw JSON response.

### Collector: get_vms_data

`get_vms_data` is added to the same collector file. It calls `_api_cached` with the VMs query above. Before returning, the caller must check whether the response contains an error with the message "VMs are not available" (or any `errors` key) and treat that as an empty domain list rather than a fatal error. Returns the raw JSON response.

### Publisher: scripts/collectors/docker.sh

Implements `publish_docker(expire)`. Calls `get_docker_data`, parses the `data.docker.containers` array with `jq`. For each container:

1. Extracts `names` (an array — use the first element), `state`, `status`, `image`, `autoStart`
2. Sanitizes the container name with `safe_name` to produce a stable UID component, e.g. `docker_nginx`
3. Calls `ha_register` to declare a binary sensor with `device_class` empty, `icon` `mdi:docker`, payload_on `ON`, payload_off `OFF`
4. Publishes state topic with value `ON` if `state == "running"`, otherwise `OFF`
5. Publishes a JSON attributes blob to the attributes topic containing: `status`, `image`, `autoStart`

Sensor UID pattern: `${MQTT_TOPIC}_docker_<safe_name>`
State topic pattern: `${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_docker_<safe_name>/state`

### Publisher: scripts/collectors/vms.sh

Implements `publish_vms(expire)`. Calls `get_vms_data`. If the response contains an `errors` key (i.e., "VMs are not available"), logs a debug message and returns immediately without publishing anything and without crashing. Otherwise parses `data.vms.domain` array with `jq`. For each VM:

1. Extracts `id`, `uuid`, `name`, `state`
2. Sanitizes `name` with `safe_name`, e.g. `vm_windows11`
3. Calls `ha_register` to declare a binary sensor with `icon` `mdi:virtual-machine`, payload_on `ON`, payload_off `OFF`
4. Publishes state topic with value `ON` if `state == "running"`, otherwise `OFF`
5. Publishes a JSON attributes blob containing: `state` (raw string), `uuid`

Sensor UID pattern: `${MQTT_TOPIC}_vm_<safe_name>`
State topic pattern: `${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_vm_<safe_name>/state`

### Config additions

New variables in `config.cfg` with defaults:

| Variable | Default | Meaning |
|---|---|---|
| `PUBLISH_DOCKER` | `true` | Master enable/disable for Docker metrics |
| `INTERVAL_DOCKER` | `30` | Publish interval in seconds |
| `EXPIRE_DOCKER` | `0` | HA `expire_after` seconds; 0 = no expiry |
| `PUBLISH_VMS` | `true` | Master enable/disable for VM metrics |
| `INTERVAL_VMS` | `30` | Publish interval in seconds |
| `EXPIRE_VMS` | `0` | HA `expire_after` seconds; 0 = no expiry |

### Main loop wiring

In `mqtt_monitor.sh`, add two new `_publish_metric` calls after the existing `shares` block, one for `publish_docker` and one for `publish_vms`, following the identical pattern used by every other metric group. Add matching re-publish calls in the HA-came-online block.

### UI page additions

In `unraid-stats2mqtt.page`, add two new setting groups — one for Docker and one for VMs — mirroring the existing interval/expire/enable fields for other metric groups.

## Open Questions

None. All schema questions have been resolved via live probing on Unraid 7.2.5.

## Acceptance Criteria

- [ ] `get_docker_data` returns valid JSON from the Unraid GraphQL API and is cached per tick
- [ ] `get_vms_data` returns valid JSON from the Unraid GraphQL API and is cached per tick
- [ ] `publish_docker` publishes one HA binary sensor per container with state ON/OFF derived from `state == "running"`
- [ ] Each Docker binary sensor has attributes: `status`, `image`, `autoStart`
- [ ] `publish_vms` publishes one HA binary sensor per VM with state ON/OFF derived from `state == "running"`
- [ ] Each VM binary sensor has attributes: `state` (raw string), `uuid`
- [ ] When the VMs API returns an error ("VMs are not available" or any `errors` key), `publish_vms` logs a debug message and returns without crashing
- [ ] Setting `PUBLISH_DOCKER=false` or `INTERVAL_DOCKER=0` completely disables Docker publishing
- [ ] Setting `PUBLISH_VMS=false` or `INTERVAL_VMS=0` completely disables VM publishing
- [ ] Both metric groups are re-published when HA comes back online
- [ ] Sensor UIDs are stable across daemon restarts (derived from container/VM name only, not runtime-assigned IDs)
- [ ] Both metric groups appear in the plugin UI settings page

# VM and Docker Container Metrics

## Status
planned

## Summary
Add per-VM and per-Docker-container sensors to unraid-stats2mqtt. Each VM and each Docker container gets its own Home Assistant sensor whose state reflects the running status of that workload. Attributes carry identifying metadata. Users can choose to publish all VMs/containers or a named allowlist. All data is sourced exclusively from the Unraid GraphQL API — no CLI tools (no virsh, no docker CLI).

## Goals
- Publish one HA sensor per VM, with state = current VM power state (e.g. `running`, `paused`, `shut off`)
- Publish one HA sensor per Docker container, with state = current container status (e.g. `running`, `stopped`, `exited`)
- Expose identifying metadata as JSON attributes on each sensor (name, image/template, ID, etc.)
- Support an allowlist config so users can restrict publishing to specific named VMs or containers
- Follow the existing `_publish_metric` / `ha_register` / `graphql_query` pattern exactly
- Add two new publisher files: `publishers/unraid-api/vms.sh` and `publishers/unraid-api/docker.sh`
- Add two new `_api_cached` helper functions in `collectors/unraid-api.sh`: `get_vms_data` and `get_docker_data`
- Wire both metrics into the main loop in `mqtt_monitor.sh` with their own `INTERVAL_VMS` and `INTERVAL_DOCKER` config knobs
- Register both metric groups in the plugin UI page (`unraid-stats2mqtt.page`)

## Non-goals
- CPU usage, memory usage, or other resource consumption metrics per container/VM (not exposed by the API)
- Network stats per container or VM
- Start/stop/restart controls (mutations are out of scope)
- Support for `onchange` publish mode (interval-only, consistent with current API-backed metrics)
- Any data source other than the Unraid GraphQL API

## Design

### API dependency and verification

The Unraid GraphQL API is the sole data source. Based on live introspection of Unraid 7.x, the top-level query type does not currently expose `docker` or `vms` fields. Before implementation can begin, the exact GraphQL query paths must be confirmed against the live API or the public schema at `https://studio.apollographql.com/public/Unraid-API/variant/current/schema/reference`.

If the API does expose these resources, the expected query shapes are:

**VMs** — likely under a top-level `vms` or `domains` field returning an array of domain objects. Expected fields per VM: `name`, `status` (power state string), `id`, `coreCount`, `ramSize`, `description`, `template` or similar. The query would be added to `collectors/unraid-api.sh` as `get_vms_data`.

**Docker containers** — likely under a top-level `docker` or `containers` field returning an array. Expected fields per container: `name`, `status`, `image`, `id`, `autoStart`, `created` or similar. The query would be added to `collectors/unraid-api.sh` as `get_docker_data`.

Both functions would follow the `_api_cached` pattern to avoid redundant HTTP calls within a single tick.

### Publisher: vms.sh

`publishers/unraid-api/vms.sh` implements `publish_vms(expire, retain)`. It calls `get_vms_data`, iterates over the array of VM objects with `jq`, and for each VM:

1. Sanitizes the VM name with `safe_name` to produce a stable UID component (e.g. `vm_mywindowsvm`)
2. Calls `ha_register` to register a sensor with `device_class` empty, `icon` `virtual-machine`, state topic `${MQTT_BASE_TOPIC}/sensor/${MQTT_TOPIC}_vm_<safe_name>/state`
3. Calls `mqtt_publish` on the state topic with the power state value
4. Publishes a JSON attributes blob to an attributes topic containing: `name`, `id`, `status`, and any available metadata fields
5. Calls `ha_register` with `json_attributes_topic` pointing at the attributes topic

If `VM_ALLOWLIST` is non-empty (comma-separated VM names from config), only VMs whose name appears in the list are published. Unregistered VMs from a previous tick that no longer appear are not actively unregistered — topic expiry handles cleanup if `EXPIRE_VMS` is configured.

### Publisher: docker.sh

`publishers/unraid-api/docker.sh` implements `publish_docker(expire, retain)`. Identical structure to `vms.sh`: iterates containers, sanitizes name to produce a UID component (e.g. `docker_nginx`), registers a sensor with `icon` `docker`, publishes state = container status string, publishes attributes JSON.

If `DOCKER_ALLOWLIST` is non-empty, only listed containers are published.

### Config additions

New variables in `config.cfg` (with defaults):

| Variable | Default | Meaning |
|---|---|---|
| `INTERVAL_VMS` | `30` | Publish interval in seconds; `0` disables |
| `EXPIRE_VMS` | `0` | HA `expire_after` seconds |
| `RETAIN_VMS` | `true` | MQTT retain flag |
| `VM_ALLOWLIST` | `` | Comma-separated VM names; empty = publish all |
| `INTERVAL_DOCKER` | `30` | Publish interval in seconds; `0` disables |
| `EXPIRE_DOCKER` | `0` | HA `expire_after` seconds |
| `RETAIN_DOCKER` | `true` | MQTT retain flag |
| `DOCKER_ALLOWLIST` | `` | Comma-separated container names; empty = publish all |

### Main loop wiring

In `mqtt_monitor.sh`, after the existing `shares` metric block, add two new `_publish_metric` calls following the exact same pattern as every other metric group. Add corresponding blocks in the HA-came-online re-publish section.

### UI page additions

In `unraid-stats2mqtt.page`, add two new setting groups in the Settings section — one for VMs and one for Docker — mirroring the existing interval/expire/retain/allowlist fields for other metric groups.

### Sensor naming convention

- VM sensor UID: `vm_<safe_name>` where `safe_name` converts the VM name to lowercase alphanumeric with underscores
- Docker sensor UID: `docker_<safe_name>`
- State value for VMs: raw string from the API (e.g. `running`, `shut off`, `paused`)
- State value for Docker containers: raw string from the API (e.g. `running`, `stopped`, `exited`)

## Open Questions

- **API availability**: The Unraid GraphQL API may not yet expose `vms` or `docker` as top-level query fields. This must be verified on the target Unraid version before implementation. If the fields do not exist, implementation must be deferred until Unraid adds them.
- **Exact query shape**: The field names, nesting, and available subfields for VM and Docker objects need to be confirmed from the live API or the Apollo Studio schema reference.
- **VM state string values**: Need to confirm what string values the API returns for VM power states (libvirt uses `running`, `paused`, `shut off`, `crashed`, etc.) and whether the API normalizes these.
- **Docker status string values**: Need to confirm what string values the API returns (Docker uses `running`, `exited`, `paused`, `restarting`, `dead`, `created`).
- **Container name vs. container ID**: The allowlist should match on human-readable container name. Confirm the API exposes a stable `name` field.
- **Stale sensor cleanup**: When a VM or container is removed from Unraid, its MQTT topic persists until expiry. Should the publisher actively call `ha_unregister` for VMs/containers that were present on a previous tick but are now absent? This requires state tracking across ticks (similar to how disk publishers handle removed disks).

## Acceptance Criteria

- [ ] `get_vms_data` in `collectors/unraid-api.sh` returns valid JSON from the Unraid API and is cached per tick
- [ ] `get_docker_data` in `collectors/unraid-api.sh` returns valid JSON from the Unraid API and is cached per tick
- [ ] `publish_vms` publishes one HA sensor per VM (or per allowlisted VM) with state = power state
- [ ] `publish_docker` publishes one HA sensor per container (or per allowlisted container) with state = status
- [ ] Each sensor has a JSON attributes topic containing name and available metadata
- [ ] Setting `INTERVAL_VMS=0` or `INTERVAL_DOCKER=0` completely disables that metric group
- [ ] `VM_ALLOWLIST=MyVM1,MyVM2` causes only those two VMs to be published; others are skipped
- [ ] `DOCKER_ALLOWLIST=nginx,homeassistant` causes only those two containers to be published
- [ ] Both metric groups appear in the plugin UI settings page
- [ ] Both metric groups are re-published when HA comes back online
- [ ] Sensor UIDs are stable across restarts (derived from name only, not from a runtime-assigned ID)
- [ ] If the API returns an error or the `vms`/`docker` query field does not exist, the publisher logs a warning and returns without crashing the daemon

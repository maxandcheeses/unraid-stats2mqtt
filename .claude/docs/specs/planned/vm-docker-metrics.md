# VM and Docker Container Metrics

## Status
planned

## Summary
Add per-VM and per-Docker-container binary sensors to unraid-stats2mqtt. Each Docker container and each VM gets one HA binary sensor whose state reflects whether the workload is currently running. Attributes carry identifying metadata. All data is sourced from the Unraid GraphQL API using the confirmed query shapes from Unraid 7.2.5. The settings page dynamically discovers containers and VMs from the API and lets the user toggle which entities are exposed as sensors. Each group (Docker and VMs) supports an include/exclude mode that controls whether the checkbox list is an allowlist or a denylist.

## Goals
- Publish one HA binary sensor per Docker container: ON when `state` is `running`, OFF otherwise; attributes include `status`, `image`, `autoStart`
- Publish one HA binary sensor per VM: ON when `state` is `running`, OFF otherwise; attributes include `state` (raw string) and `uuid`
- Guard against the "VMs are not available" API error so a VM-less system does not crash the daemon
- Follow the existing `_publish_metric` / `ha_register` / `_api_cached` pattern exactly
- Add two new collector files: `scripts/collectors/docker.sh` and `scripts/collectors/vms.sh`
- Add `get_docker_data` and `get_vms_data` functions using `_api_cached` in the existing unraid-api collector file
- Wire both metrics into the main loop in `mqtt_monitor.sh` and the HA-came-online re-publish block
- Add corresponding config knobs and a dynamic entity-selection UI in the settings page
- Support per-group include/exclude mode so users can either allowlist or denylist specific entities

## Non-goals
- CPU usage, memory usage, network stats, or any other resource consumption metrics per container or VM
- Start/stop/restart controls (mutations are out of scope)
- `onchange` publish mode (interval-only, consistent with existing API-backed metrics)
- Per-entity interval/expire/retain knobs (group-level knobs only)
- The special `"*"` wildcard value for sensor lists (explicit name lists only)
- Any data source other than the Unraid GraphQL API

## Design

### GraphQL queries

The confirmed query shapes for Unraid 7.2.5 are:

**Docker:** `{ docker { containers { id names state status image autoStart } } }`

The `docker` top-level field returns a `Docker` type whose only valid field is `containers`. Each element is a `DockerContainer` with fields: `id`, `names`, `state`, `status`, `image`, `imageId`, `autoStart`, `ports { ip privatePort publicPort type }`. The query above requests only the fields needed for publishing; `ports` and `imageId` are omitted.

**VMs:** `{ vms { domain { id uuid name state } } }`

The `vms` top-level field returns a `Vms` type whose only valid field is `domain`. Each element is a `VmDomain` with confirmed fields: `id`, `uuid`, `name`, `state`. When VMs are not running or not configured, the API returns an error payload with message "VMs are not available" rather than an empty array.

### Collector: get_docker_data

`get_docker_data` is added to the existing unraid-api collector file. It calls `_api_cached` with the Docker query above. The result is cached for the duration of the tick. Returns the raw JSON response.

### Collector: get_vms_data

`get_vms_data` is added to the same collector file. It calls `_api_cached` with the VMs query above. The caller checks whether the response contains any `errors` key and treats that as an empty domain list rather than a fatal error. Returns the raw JSON response.

### Include/exclude mode

Each group has an independent mode setting. The mode is stored in `DOCKER_SENSOR_MODE` and `VM_SENSOR_MODE`. Valid values are `include` and `exclude`. Default is `include` for both.

The `DOCKER_SENSORS` and `VM_SENSORS` comma-separated lists serve dual purpose depending on the mode:

- **include mode:** the list is an allowlist. Only entities whose name appears in the list are published. An empty list means nothing is published.
- **exclude mode:** the list is a denylist. All entities are published except those whose name appears in the list. An empty list means all entities are published.

The mode has no effect on how names are stored — in both modes, the list contains entity names. The meaning of the list (allow vs. deny) is what changes.

### Publisher: scripts/collectors/docker.sh

Implements `publish_docker(expire)`. Reads `DOCKER_SENSORS` and `DOCKER_SENSOR_MODE` from config. Calls `get_docker_data` and parses the `data.docker.containers` array with `jq`. For each container:

1. Extracts `names` (an array — use the first element, strip leading `/`), `state`, `status`, `image`, `autoStart`
2. Applies the mode filter:
   - If `DOCKER_SENSOR_MODE` is `include`: skip the container if its stripped name is NOT in `DOCKER_SENSORS`. If `DOCKER_SENSORS` is empty, skip all containers.
   - If `DOCKER_SENSOR_MODE` is `exclude`: skip the container if its stripped name IS in `DOCKER_SENSORS`. If `DOCKER_SENSORS` is empty, publish all containers.
3. Sanitizes the container name with `safe_name` to produce a stable UID component, e.g. `docker_nginx`
4. Calls `ha_register` to declare a binary sensor with `device_class` empty, `icon` `mdi:docker`, `payload_on` `ON`, `payload_off` `OFF`
5. Publishes state topic with value `ON` if `state == "running"`, otherwise `OFF`
6. Publishes a JSON attributes blob to the attributes topic containing: `status`, `image`, `autoStart`

Sensor UID pattern: `${MQTT_TOPIC}_docker_<safe_name>`
State topic pattern: `${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_docker_<safe_name>/state`

### Publisher: scripts/collectors/vms.sh

Implements `publish_vms(expire)`. Reads `VM_SENSORS` and `VM_SENSOR_MODE` from config. Calls `get_vms_data`. If the response contains an `errors` key ("VMs are not available" or similar), logs a debug message and returns without crashing. Otherwise parses `data.vms.domain` array with `jq`. For each VM:

1. Extracts `id`, `uuid`, `name`, `state`
2. Applies the mode filter:
   - If `VM_SENSOR_MODE` is `include`: skip the VM if its name is NOT in `VM_SENSORS`. If `VM_SENSORS` is empty, skip all VMs.
   - If `VM_SENSOR_MODE` is `exclude`: skip the VM if its name IS in `VM_SENSORS`. If `VM_SENSORS` is empty, publish all VMs.
3. Sanitizes `name` with `safe_name`, e.g. `vm_windows11`
4. Calls `ha_register` to declare a binary sensor with `icon` `mdi:virtual-machine`, `payload_on` `ON`, `payload_off` `OFF`
5. Publishes state topic with value `ON` if `state == "running"`, otherwise `OFF`
6. Publishes a JSON attributes blob containing: `state` (raw string), `uuid`

Sensor UID pattern: `${MQTT_TOPIC}_vm_<safe_name>`
State topic pattern: `${MQTT_BASE_TOPIC}/binary_sensor/${MQTT_TOPIC}_vm_<safe_name>/state`

### Config additions

New variables in `config.cfg` with defaults:

| Variable | Default | Meaning |
|---|---|---|
| `PUBLISH_DOCKER` | `true` | Master enable/disable for Docker metrics |
| `INTERVAL_DOCKER` | `30` | Publish interval in seconds |
| `EXPIRE_DOCKER` | `0` | HA `expire_after` seconds; 0 = no expiry |
| `RETAIN_DOCKER` | `false` | MQTT retain flag for Docker sensor messages |
| `DOCKER_SENSOR_MODE` | `include` | `include` = publish only listed; `exclude` = publish all except listed |
| `DOCKER_SENSORS` | `` | Comma-separated container names; allowlist in include mode, denylist in exclude mode |
| `PUBLISH_VMS` | `true` | Master enable/disable for VM metrics |
| `INTERVAL_VMS` | `30` | Publish interval in seconds |
| `EXPIRE_VMS` | `0` | HA `expire_after` seconds; 0 = no expiry |
| `RETAIN_VMS` | `false` | MQTT retain flag for VM sensor messages |
| `VM_SENSOR_MODE` | `include` | `include` = publish only listed; `exclude` = publish all except listed |
| `VM_SENSORS` | `` | Comma-separated VM names; allowlist in include mode, denylist in exclude mode |

The effective publish behavior by mode and list state:

| Mode | List | Result |
|---|---|---|
| `include` | empty | publish nothing |
| `include` | non-empty | publish only listed names |
| `exclude` | empty | publish all |
| `exclude` | non-empty | publish all except listed names |

### Main loop wiring

In `mqtt_monitor.sh`, add two new `_publish_metric` calls after the existing `shares` block, one for `publish_docker` and one for `publish_vms`, following the identical pattern used by every other metric group. Add matching re-publish calls in the HA-came-online block.

### Settings page: dynamic entity discovery

The settings page (`unraid-stats2mqtt.page`) adds a new section below the Per-Metric Publish Rules table. This section is rendered by the PHP backend and contains two groups: "Docker Containers" and "Virtual Machines".

**API calls at page load**

The PHP backend reads `UNRAID_API_KEY` and `UNRAID_API_HOST` from the loaded config. If either is missing or empty, the section renders a single placeholder message: "Configure your API key above to discover containers/VMs."

If both are present, the PHP backend makes two HTTP POST requests to the Unraid GraphQL endpoint (using `curl` or a PHP HTTP call, whichever is available in the Unraid PHP environment):

- Docker query: `{ docker { containers { id names state status image autoStart } } }`
- VM query: `{ vms { domain { id uuid name state } } }`

Each request is made with the `x-api-key` header set to `UNRAID_API_KEY`. Failures (HTTP error, JSON parse error, `errors` key in response) are caught per-group. If a group's request fails, that group renders its own inline error message rather than failing the whole page.

**Group mode toggle**

At the top of each group (Docker Containers and Virtual Machines), render a mode toggle before the entity table. The toggle is a pair of radio buttons (or a styled toggle) with two options:

- "Publish selected" — maps to `include` mode
- "Publish all (exclude checked)" — maps to `exclude` mode

The selected option reflects the current `DOCKER_SENSOR_MODE` or `VM_SENSOR_MODE` config value. These radio buttons are named `DOCKER_SENSOR_MODE` and `VM_SENSOR_MODE` respectively and are submitted with the form POST directly (no hidden input needed, since radio buttons carry their value naturally).

When the user switches the mode toggle, JavaScript updates a visible label or note below the toggle to clarify the current meaning of the checkboxes:

- In `include` mode: no extra label needed (default behavior is self-explanatory)
- In `exclude` mode: display a short note such as "Checked items will be excluded from publishing"

The label update happens immediately on toggle change without a page reload.

**Docker Containers group**

Renders a mode toggle (described above) followed by a table with one row per container. Columns:

- Checkbox: in `include` mode, checked if the container's stripped name is in `DOCKER_SENSORS`; in `exclude` mode, checked if the container's stripped name is in `DOCKER_SENSORS` (the denylist)
- Name: the first element of `names`, with leading `/` stripped
- State badge: green "RUNNING" if `state == "running"`, gray badge with the raw state value otherwise
- Image: the `image` field value

All checkboxes share the name attribute `docker_sensor_toggle` (or similar). A hidden `<input name="DOCKER_SENSORS">` field holds the current comma-separated list and is updated by JavaScript when any checkbox changes: the JS reads all checked container names, joins them with commas, and writes the result into the hidden input. On form submit, this hidden input is included in the POST body to `/update.php` alongside all other config fields.

**Virtual Machines group**

Renders a mode toggle (described above) followed by a table with one row per VM. Columns:

- Checkbox: in `include` mode, checked if the VM's name is in `VM_SENSORS`; in `exclude` mode, checked if the VM's name is in `VM_SENSORS` (the denylist)
- Name: the `name` field
- State badge: green "RUNNING" if `state == "running"`, gray badge with the raw state value otherwise
- UUID: the `uuid` field value

Same hidden-input + JS pattern as Docker: a hidden `<input name="VM_SENSORS">` is updated on checkbox change and submitted with the form.

**Form submission**

The hidden inputs (`DOCKER_SENSORS` and `VM_SENSORS`) and the radio inputs (`DOCKER_SENSOR_MODE` and `VM_SENSOR_MODE`) are submitted via the existing `/update.php` form POST that handles all other config saves. No new endpoints are required. The `/update.php` handler treats all four as plain string config values and writes them to `config.cfg`.

**Interval/expire/retain controls**

`INTERVAL_DOCKER`, `EXPIRE_DOCKER`, `RETAIN_DOCKER`, `INTERVAL_VMS`, `EXPIRE_VMS`, and `RETAIN_VMS` remain as single-row entries in the Per-Metric Publish Rules table, identical in structure to every other metric group's rows. They are not moved to the dynamic entity section.

## Open Questions

None. All schema questions resolved via live probing on Unraid 7.2.5. Entity-selection UI requirements confirmed. Include/exclude mode requirements confirmed.

## Acceptance Criteria

- [ ] `get_docker_data` returns valid JSON from the Unraid GraphQL API and is cached per tick
- [ ] `get_vms_data` returns valid JSON from the Unraid GraphQL API and is cached per tick
- [ ] In `include` mode, `publish_docker` publishes only the containers listed in `DOCKER_SENSORS`; containers not in the list are silently skipped
- [ ] In `include` mode, `publish_docker` publishes nothing when `DOCKER_SENSORS` is empty
- [ ] In `exclude` mode, `publish_docker` publishes all containers except those listed in `DOCKER_SENSORS`
- [ ] In `exclude` mode, `publish_docker` publishes all containers when `DOCKER_SENSORS` is empty
- [ ] Each published Docker binary sensor has state ON when `state == "running"`, OFF otherwise
- [ ] Each Docker binary sensor has attributes: `status`, `image`, `autoStart`
- [ ] In `include` mode, `publish_vms` publishes only the VMs listed in `VM_SENSORS`; VMs not in the list are silently skipped
- [ ] In `include` mode, `publish_vms` publishes nothing when `VM_SENSORS` is empty
- [ ] In `exclude` mode, `publish_vms` publishes all VMs except those listed in `VM_SENSORS`
- [ ] In `exclude` mode, `publish_vms` publishes all VMs when `VM_SENSORS` is empty
- [ ] Each published VM binary sensor has state ON when `state == "running"`, OFF otherwise
- [ ] Each VM binary sensor has attributes: `state` (raw string), `uuid`
- [ ] When the VMs API returns an error ("VMs are not available" or any `errors` key), `publish_vms` logs a debug message and returns without crashing
- [ ] Setting `PUBLISH_DOCKER=false` or `INTERVAL_DOCKER=0` completely disables Docker publishing
- [ ] Setting `PUBLISH_VMS=false` or `INTERVAL_VMS=0` completely disables VM publishing
- [ ] Both metric groups are re-published when HA comes back online
- [ ] Sensor UIDs are stable across daemon restarts (derived from container/VM name only, not runtime-assigned IDs)
- [ ] `DOCKER_SENSOR_MODE` defaults to `include` and `VM_SENSOR_MODE` defaults to `include`
- [ ] Settings page renders a mode toggle at the top of the Docker Containers group reflecting the current `DOCKER_SENSOR_MODE` value
- [ ] Settings page renders a mode toggle at the top of the Virtual Machines group reflecting the current `VM_SENSOR_MODE` value
- [ ] Switching the mode toggle to "Publish all (exclude checked)" displays a clarifying note that checked items will be excluded
- [ ] Switching the mode toggle back to "Publish selected" removes or hides the exclusion note
- [ ] Mode toggle selection is submitted as `DOCKER_SENSOR_MODE` / `VM_SENSOR_MODE` via the form POST and saved to `config.cfg`
- [ ] In both modes, the checkbox state reflects whether the entity name is in the stored list (allowlist in include, denylist in exclude)
- [ ] Settings page renders the Docker Containers section with one row per container discovered from the API
- [ ] Settings page renders the Virtual Machines section with one row per VM discovered from the API
- [ ] Each row shows a toggle checkbox, entity name, current state badge, and image (Docker) or uuid (VM)
- [ ] State badge is green for RUNNING, gray for any other state
- [ ] Checking/unchecking a container or VM checkbox updates the corresponding hidden input in real time via JavaScript
- [ ] Submitting the settings form saves the updated `DOCKER_SENSORS` and `VM_SENSORS` values to `config.cfg`
- [ ] When `UNRAID_API_KEY` or `UNRAID_API_HOST` is not configured, the entity-discovery section shows the placeholder message instead of an empty table
- [ ] If the Docker API call fails at page load, the Docker group shows an inline error without breaking the VM group or the rest of the page
- [ ] If the VM API call fails at page load, the VM group shows an inline error without breaking the Docker group or the rest of the page
- [ ] `INTERVAL_DOCKER`, `EXPIRE_DOCKER`, `RETAIN_DOCKER`, `INTERVAL_VMS`, `EXPIRE_VMS`, `RETAIN_VMS` appear as rows in the Per-Metric Publish Rules table, not in the entity-discovery section

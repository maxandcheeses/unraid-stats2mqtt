# GraphQL API Migration (Drop INI Files + SMART)

## Status
planned

## Summary
Migrate unraid-stats2mqtt from reading Unraid's internal `/var/local/emhttp/*.ini` files and calling `smartctl` directly to sourcing all metrics through the Unraid GraphQL API (`http://localhost/graphql`). SMART sensors are dropped entirely. Network interface speeds and disk R/W speeds remain on `/proc` reads because the API does not expose per-tick byte counts. This migration targets Unraid 6.12+, where the GraphQL API and API key authentication are stable.

## Goals
- Remove all reads of `/var/local/emhttp/var.ini`, `disks.ini`, `monitor.ini`, `shares.ini`
- Remove all `smartctl` invocations and the SMART sensor group (`publish_smart`, associated `ha_register` calls, `_unregister_disk_sensors` entries for SMART UIDs)
- Add `lib/api.sh` providing a reusable `graphql_query` function that handles auth, HTTP, and response extraction
- Add `UNRAID_API_KEY` to `config.cfg` and `load_config` in `lib/config.sh`
- Expose `UNRAID_API_KEY` in the plugin settings UI (`unraid-stats2mqtt.page`)
- Re-implement the publisher functions in `var_ini.sh`, `disks_ini.sh`, `monitor_ini.sh`, and `shares_ini.sh` to call the API instead of reading INI files
- Gracefully skip a metric group when the API is unavailable or returns an error, logging a warning without crashing the daemon
- Keep `network.sh` (reads `/proc/net/dev`) and the `publish_rw_speeds` function in `disks_ini.sh` (reads `/proc/diskstats`) unchanged

## Non-goals
- Adding new metrics beyond what was previously covered by the INI files
- Supporting Unraid versions below 6.12
- Providing a fallback to INI file parsing when the API is unavailable (skip-and-log is sufficient)
- Caching API responses to disk between ticks (in-memory only)
- Using jq (treat it as absent; use awk/grep/sed)

## Design

### jq availability check
Before committing to a pure awk/grep approach, `lib/api.sh` should probe for `jq` at daemon startup (once, in `mqtt_monitor.sh`) and set a module-level variable `_HAS_JQ`. The `graphql_query` helper uses `jq` when available and falls back to awk/grep pattern extraction otherwise. This avoids over-engineering the parser for a tool that likely ships with recent Unraid builds but cannot be assumed.

### lib/api.sh
New file sourced by `mqtt_monitor.sh` alongside the other lib files.

Responsibilities:
- Expose `graphql_query <query_string>` — sends the query via `curl` to `http://localhost/graphql` with headers `Content-Type: application/json` and `x-api-key: $UNRAID_API_KEY`. Returns the raw response body on stdout; sets a non-zero exit code and logs on HTTP or curl error.
- Expose `api_field <json_blob> <field_path>` — thin wrapper that extracts a single scalar value from a JSON blob using jq (if available) or a targeted awk/grep expression. For complex nested extraction, each caller constructs its own awk pipeline; `api_field` handles simple `data.foo.bar` paths only.
- On curl failure (no route, connection refused, timeout), log a warning at WARN level using `log` and return exit code 1. Callers check the exit code and return early, causing `_publish_metric` to publish nothing for that tick.
- `UNRAID_API_KEY` is read from the already-loaded config environment; `lib/api.sh` does not call `load_config` itself.
- Set a short curl timeout (e.g. 5 seconds connect, 10 seconds max) to avoid stalling the 10-second tick loop.

### SMART removal
In `disks_ini.sh`:
- Delete `publish_smart()` entirely.
- Remove the four SMART `ha_register` / `mqtt_publish` calls (`_smart_health`, `_reallocated`, `_pending_sectors`, `_offline_uncorrectable`) from wherever they appear.
- Remove the corresponding `ha_unregister` lines from `_unregister_disk_sensors`.
- Remove `RETAIN_SMART` references from `lib/config.sh` and `unraid-stats2mqtt.page`.
- Remove `PUBLISH_SMART` and `INTERVAL_SMART` / `EXPIRE_SMART` references from `lib/loop.sh` dispatch and from any example config or UI page.

### lib/config.sh changes
- Add `UNRAID_API_KEY="${UNRAID_API_KEY:-}"` default (empty — API disabled if unset).
- Remove `RETAIN_SMART` default.

### metrics/var_ini.sh
Replace all `read_ini_section` / `ini_field` calls against `var.ini` with a single GraphQL query per publish call (or one query that fetches all needed fields). Fields to cover: array state, array capacity (used/free/total), cache pool state and usage, parity check status and progress, rebuild status and progress, Unraid version string, update-available flag, system hostname, CPU model. The exact GraphQL schema fields must be confirmed against the live API (see Open Questions), but the query structure in the spec is intentionally schema-agnostic.

### metrics/disks_ini.sh
`publish_disk_temps`, `publish_disk_states`, `publish_disk_usage`, `publish_disk_errors`, and `publish_disk_json` each replace their INI-file loop with a GraphQL query for the array disk list. The per-disk fields needed are: name, device, status/state, temperature, filesystem size/used/free, error count. The existing `safe_name` and topic/UID construction logic is unchanged. `publish_rw_speeds` is untouched (reads `/proc/diskstats`).

### metrics/monitor_ini.sh
Replace `monitor.ini` reads with API queries covering: array error counts, parity history (last check duration, errors, date), flash state, Docker vdisk usage, per-disk usage percentage, per-disk alert color. Some of these may not be directly available in the GraphQL schema; where they are absent the corresponding publisher should log a one-time warning and skip.

### metrics/shares_ini.sh
Replace `shares.ini` iteration with a GraphQL query that returns the share list with name and usage statistics. The existing JSON-blob publish format is preserved.

### unraid-stats2mqtt.page (settings UI)
Add an `UNRAID_API_KEY` field in the existing settings form. The field should be a password-type input (Unraid plugin pages use standard HTML form elements styled with Unraid's CSS classes). The label should include a note that the key is generated in Unraid WebGUI under Settings > API Keys (or the equivalent path — confirm in Open Questions). Remove the SMART-related toggle/interval/expire fields.

Unraid plugin `.page` files use a Mix syntax (PHP-in-HTML with Unraid's `<? ... ?>` tags for dynamic defaults) and render inside the Unraid management UI frame. The settings form POSTs to a handler that writes `config.cfg`. The new field follows the same pattern as the existing `MQTT_PASS` field (password input, no echo).

## Open Questions
- What GraphQL schema does Unraid 6.12+ expose for array disks, shares, parity, cache pools, and system info? The exact field names and query paths need to be confirmed by running introspection queries (`__schema`) against a live Unraid 6.12+ instance before implementation.
- Does `jq` ship with Unraid 6.12+? Run `which jq` on a target system. This determines how much awk-based JSON parsing needs to be written.
- What is the exact Unraid WebGUI path for generating API keys (for the UI label)? Confirm on a live instance.
- Does the GraphQL API expose parity history, flash state, Docker vdisk usage, and per-disk alert color? If any of these are missing, the corresponding publisher must be redesigned or dropped.
- Is the GraphQL endpoint `http://localhost/graphql` or is it available via a Unix socket? Confirm whether `curl --unix-socket` is needed for robustness when the HTTP stack is not up.
- What authentication failure response does the API return (HTTP 401? GraphQL error in body?) so error handling in `graphql_query` can be specific.

## Implementation Steps
1. Confirm Open Questions against a live Unraid 6.12+ instance (run introspection, check for jq, verify API key UI path).
2. Remove `publish_smart` and all SMART sensor references from `disks_ini.sh`, `config.sh`, `loop.sh` dispatch, and `unraid-stats2mqtt.page`.
3. Add `UNRAID_API_KEY` to `load_config` in `config.sh`.
4. Create `lib/api.sh` with `graphql_query` and `api_field`.
5. Source `lib/api.sh` in `mqtt_monitor.sh`.
6. Migrate `var_ini.sh` publishers to use `graphql_query`.
7. Migrate `disks_ini.sh` publishers (except `publish_rw_speeds`) to use `graphql_query`.
8. Migrate `monitor_ini.sh` publishers to use `graphql_query`; skip any metric whose field is absent from the schema.
9. Migrate `shares_ini.sh` to use `graphql_query`.
10. Add `UNRAID_API_KEY` field to `unraid-stats2mqtt.page`; remove SMART fields.
11. Test with `mqtt_monitor.sh test` on a Unraid 6.12+ instance with a valid API key.
12. Test graceful degradation: revoke the API key mid-run and confirm the daemon logs warnings but continues publishing `/proc`-sourced metrics.

## Acceptance Criteria
- [ ] No references to `/var/local/emhttp/*.ini` remain in any metrics file
- [ ] No calls to `smartctl` remain anywhere in `source/`
- [ ] `publish_smart` function does not exist
- [ ] SMART-related HA sensor UIDs (`_smart_health`, `_reallocated`, `_pending_sectors`, `_offline_uncorrectable`) are never registered
- [ ] `lib/api.sh` exists and `graphql_query` returns parsed output for a valid query
- [ ] `UNRAID_API_KEY` is loaded by `load_config` and used in every `graphql_query` call
- [ ] When `UNRAID_API_KEY` is empty or the API returns an error, the daemon logs a warning and skips that metric group for that tick without exiting
- [ ] All previously INI-sourced metrics (temps, states, usage, errors, array status, cache, parity, shares) still publish correctly via the API
- [ ] `publish_rw_speeds` and `network.sh` continue to read `/proc` files and are functionally unchanged
- [ ] The settings UI shows the `UNRAID_API_KEY` field and does not show SMART fields
- [ ] `build.sh` produces a valid `.txz` and the plugin installs cleanly on Unraid 6.12+

# Runbook — OSN port-to-port enable (OSN-ENABLEMENT-2)

The one-shot, gated production operation that turns **port-to-port OSN travel ON for players** by flipping
`game_config.mainship_space_movement_enabled` **false → true**. This is the player-visible finale of the
OSN/PORT-LAUNCH arc. It is **one-way operationally** (re-disabling is a separate, deliberate decision).

## Prerequisites (all met before dispatch)
- Production migration head **0068**; three starter ports **active/public** (PORT-LAUNCH).
- Current production **enablement preflight GO** (OSN-ENABLEMENT-1A, read-only, `OVERALL_PASS=true`).
- Real **authenticated backend journey** + **rendered UI** proofs green (OSN-ENABLEMENT-1B).
- `mainship_send_enabled = true`, `mainship_space_movement_enabled = false`, `OSN_COORDINATE_TRAVEL_ENABLED = false`.

## The operation (`scripts/osn-enable-operation.sql`)
One `BEGIN … COMMIT` with conservative timeouts: lock the flag rows → snapshot (both flags, head, canonical
port counts, OSN-safety structure, an md5 digest of **every other** `game_config` key) → assert preconditions
(head 0068; OSN flag currently **false** — refuses to re-enable; send true; exactly 3 ports active / 0 hidden;
exclusivity + one-active indexes + receipt idempotency + dock + move-to-location + readiness all present) →
flip **only** `mainship_space_movement_enabled` to `true` **once** → assert postconditions (flag now true via
value + `cfg_bool`; send unchanged; **every other game_config key byte-for-byte unchanged**; ports still 3
active) → emit markers → commit. Any failure rolls back; **no retry**.

Markers: `PRECONDITIONS_PASS=true`, `OSN_FLAG_BEFORE=false`, `OSN_FLAG_WRITES=1`, `OSN_FLAG_AFTER=true`,
`SEND_FLAG_UNCHANGED=true`, `OTHER_CONFIG_UNCHANGED=true`, `OSN_ENABLE_OPERATION_PASS=true`.

## Gating (`.github/workflows/osn-enable.yml`)
`workflow_dispatch` only; runs only from `refs/heads/main`; requires the typed confirmation
**`ENABLE_OSN_PORT_TO_PORT`** before any DB connection; protected `production` environment; pinned-CA +
`sslmode=verify-full` session pooler; the orchestrator also re-asserts `OSN_COORDINATE_TRAVEL_ENABLED=false`
(free-coordinate travel stays suppressed even after port-to-port is on).

## Disposable proof (`osn-enable-proof.yml`, no production)
`ok[1]` clean enable (false→true once; send + other config unchanged) · `ok[2]` wrong confirmation / non-main
rejected before any DB access · `ok[3]` invalid pre-state (already enabled / send off / port not active)
fail-closed · `ok[4]` rerun refuses to re-enable · `ok[5]` only-this-key invariance (an unexpected change to
another `game_config` key is caught + rolled back) · `ok[6]` scope guard.

## After enable
Port-to-port OSN travel is live: an anchored player sees the PortNavPanel and can sail between active ports.
Free-coordinate ("fly anywhere") travel stays off (`OSN_COORDINATE_TRAVEL_ENABLED=false`). Recovery, if ever
needed, is fix-forward / a separate deliberate re-disable — never an automatic retry.

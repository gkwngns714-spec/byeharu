# Runbook — OSN v1 enablement preflight (post-reveal current-state)

**Status:** read-only preflight refreshed for the post-reveal production state (OSN-ENABLEMENT-1A). **This does
not enable OSN.** A green run is *evidence* the operator may choose to enable; the flag flip is a separate,
explicit, human decision.

## 1. Source of truth

`scripts/osn-enablement-preflight.sql` (run by `.github/workflows/osn-enablement-preflight.yml`, manual /
production-environment-gated / read-only) is **the** current GO/NO-GO evidence for the OSN v1 enablement
decision at production migration head **0068**, with the three starter ports **active/public**.

The earlier preflight evidence (last green run predating the 0068 deploy and the reveal) is **stale** and no
longer sufficient: it was taken before the ports existed in their active state and before head 0068 was the
live shape. Re-run this refreshed preflight to obtain current evidence.

> **Historical / pre-reveal artifact (do not treat as current truth):** the dark-state catalog verifier
> `scripts/osn-hub1a-production-catalog-verify.*` asserts the three ports are **hidden** and would now fail by
> design. It is intentionally left unchanged as the pre-reveal historical record. The **current** port-state
> truth is `scripts/postreveal-verify.*`; the **current enablement** truth is this preflight. The dark-state
> verifier's `migration head 0067` header is historical and is not corrected here (out of this PR's scope).

## 2. What it asserts (all read-only)

Connection discipline (unchanged): Management-API session pooler, pinned CA, `sslmode=verify-full`, one
`begin transaction read only` + `default_transaction_read_only = on`; the SQL contains no DDL/DML/grant/flag
write and never `RAISE`s — gating lives in the calling workflow.

**Current-state sentinels emitted:**
```
MIGRATION_HEAD=0068
CANONICAL_STARTER_PORTS_EXPECTED=3
CANONICAL_STARTER_PORTS_ACTIVE=3
CANONICAL_STARTER_PORTS_HIDDEN=0
AUTHENTICATED_MAP_PORTS_VISIBLE=3
MAINSHIP_SEND_ENABLED=true
MAINSHIP_SPACE_MOVEMENT_ENABLED=false
OSN_COORDINATE_TRAVEL_ENABLED=false   (asserted by the workflow from the checked-out frontend const)
STRUCTURAL_PASS=<t|f>   OVERALL_PASS=<t|f>
```

**Retained + added safety checks** (none weakened):
- existing: head 0068; canonical authenticated RPC surface = 17; OSN command boundary authenticated-only +
  service-role-only writers/primitives/processor; arrival cron exactly-once @30s; zero/coherent active
  coordinate movements while dark; flag stored as `jsonb` and read `false`.
- added (current state → `OVERALL_PASS`): exactly three canonical ports active, zero hidden, three visible
  through `get_world_map()`; `mainship_send_enabled = true`.
- added (deployment shape → `STRUCTURAL_PASS`): the `fleets` movement-owner exclusivity CHECK; the
  one-active-move-per-ship and per-fleet partial unique indexes; the receipt `(main_ship_id, request_id)`
  idempotency constraint; `mainship_space_dock_at_location` service-role-only; the location-target wrapper
  authenticated; `get_osn_movement_readiness` authenticated.
- added (frontend gate, workflow-side): `OSN_COORDINATE_TRAVEL_ENABLED = false` — free-coordinate travel
  stays suppressed; the production workflow fails closed if it is not false.

## 3. Disposable proof

`scripts/osn-enablement-preflight-proof.sh` + `.github/workflows/osn-enablement-preflight-proof.yml` run the
**actual** preflight SQL on a throwaway chain 0001..0068 (post-reveal state created by a direct status update —
`reveal_starter_ports()` is never called):
```
ok[1] expected post-reveal baseline passes (OVERALL_PASS=true + all sentinels)
ok[2] hidden / wrong-count starter-port state fails
ok[3] either feature-flag deviation (space=true / send=false) fails
ok[4] OSN boundary/ACL failure (writer granted to authenticated) fails, then restores
ok[5] coordinate-travel exposure (const = true) is detected and fails
ok[6] scope guard: no migration / frontend / gameplay / home-port / flag-default change
```

## 4. Not in this phase

No production dispatch, no flag change (`mainship_space_movement_enabled` stays `false`,
`mainship_send_enabled` stays `true`), no `reveal_starter_ports()`, no migration, no frontend/gameplay/home-port
change, no authenticated OSN smoke test. The actual enablement remains a separate, explicit, human-gated step
taken only after a fresh green production run of this preflight.

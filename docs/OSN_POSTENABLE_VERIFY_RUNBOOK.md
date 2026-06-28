# Runbook — independent post-enable verification (OSN-ENABLEMENT-2E)

**Status:** verifier built and proved on a disposable stack. **Not run against production** during this phase;
dispatching it is a separate, explicitly-authorized step after merge (it stops at the protected production
gate).

The independent, **read-only** confirmation that live production matches the approved **post-enable** baseline
(OSN port-to-port travel is ON), separate from the enable operation's own transaction log.

## Why a new verifier (not a reused one)
Every pre-enable verifier — `osn-enablement-preflight.*`, `postreveal-verify.*`, `osn-hub1a-production-catalog-verify.*`
— asserts `mainship_space_movement_enabled = false` and now **fails by design**. They are historical /
pre-enable evidence and are left unchanged. OSN-ENABLEMENT-2E adds an explicitly **post-enable** verifier
asserting the flag is **true**.

## What it asserts (read-only)
One `BEGIN … REPEATABLE READ READ ONLY` + `SET LOCAL default_transaction_read_only = on` snapshot that emits
`KEY=value` lines and `ROLLBACK`s. Two layers:
- **Catalog/config:** head `0068`; `mainship_send_enabled=true`; `mainship_space_movement_enabled=TRUE`; zero
  tracked-flag config deviation; exactly three canonical ports active (approved identity), 0 hidden; the OSN
  command surface ACL (move-to-location authenticated; the writer + dock primitive service-role-only with
  auth/anon denied; readiness authenticated); the movement-owner exclusivity CHECK + one-active-move indexes
  + receipt idempotency constraint; no fleet holding both a legacy and an OSN movement.
- **Authenticated boundary:** `get_world_map()` exposes exactly the three active ports (no hidden / unexpected
  starter id; only active locations); and OSN readiness is structurally available (flag on + readiness
  present + ≥2 active ports, so an anchored player resolves `osn_available=true` with the current port excluded).

Emitted sentinels: `MIGRATION_HEAD=0068`, `CANONICAL_STARTER_PORTS_EXPECTED/ACTIVE/HIDDEN`,
`AUTHENTICATED_MAP_PORTS_EXPECTED/VISIBLE`, `MAINSHIP_SEND_ENABLED=true`, `MAINSHIP_SPACE_MOVEMENT_ENABLED=true`,
`OSN_COORDINATE_TRAVEL_ENABLED=false` (workflow-side, from the frontend const), `UNEXPECTED_CONFIG_CHANGES=0`,
`OVERALL_PASS`.

The **behavioral** readiness assertion (an anchored player gets `osn_available=true`, current port excluded,
active destinations eligible) is proved in the **disposable** matrix with a throwaway anchored test user
(readiness is a read; no movement command is issued; the user is deleted). Production verification is
structural only — it never creates a player and issues no command.

## Read-only / safety enforcement
The DB-free self-test rejects write/DDL and any **callable** reference to `reveal_starter_ports`,
`mainship_space_begin_move`, `command_main_ship_space_move`, or `mainship_space_stop` — these names appear in
the verifier ONLY inside single-quoted `to_regprocedure(...)` catalog lookups (oid resolution; cannot
execute). Connection = pinned-CA + `verify-full` + Management-API session pooler; weaker TLS / 6543 / system
CA / target overrides rejected.

## Disposable proof
`ok[1]` expected post-enable state passes (+ anchored-player readiness available) · `ok[2]` OSN flag false
fails · `ok[3]` coordinate-travel flag true fails · `ok[4]` wrong active/hidden port state fails · `ok[5]`
authenticated map mismatch fails · `ok[6]` unexpected configuration change fails · `ok[7]` write-capable
verifier content is rejected · `ok[8]` scope guard.

## Workflows
- `osn-postenable-verify.yml` — `workflow_dispatch` only, main-only, `environment: production` (human-gated),
  self-test gate, then the read-only verification. **Not dispatched during 2E.**
- `osn-postenable-verify-proof.yml` — disposable proof (no `environment:`).

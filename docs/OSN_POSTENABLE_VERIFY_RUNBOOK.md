# Runbook — independent CURRENT-STATE production verification (head 0070, OSN-COORD-GATE-1)

**Status / classification:** this is **THE current-state, read-only production verifier**. Repinned to
production **migration head `0070`** (OSN-COORD-GATE-1: the server-authoritative free-coordinate-travel gate).
Dispatching it against production is a separate, explicitly-authorized read-only step (it stops at the
protected `environment: production` gate).

The independent, **read-only** confirmation that live production matches the approved current state — OSN
port-to-port ON, the Phase-9 dock-services read surface live, and **free coordinate travel server-gated OFF**
— separate from any operation's own transaction log.

> **Why this repin exists (OSN-COORD-VERIFY-1).** Migration `0070` seeds
> `mainship_coordinate_travel_enabled` with `INSERT ... ON CONFLICT DO NOTHING`, so a *successful deploy does
> not prove the live value is false* (a pre-existing row could have retained another value). The prior
> production verifier run was pinned to head `0069` and executed **before** `0070` deployed. Therefore the
> live value of the coordinate gate was **unproven**. This verifier closes that gap: it expects head `0070`
> and **reads the actual stored value of all three flags from the database**, fail-closed.

## Verifier classification (so operators don't run the wrong one)
- **CURRENT-STATE (run this):** `osn-postenable-verify.*` — expects head **0070**, ports active,
  `mainship_send_enabled=true`, `mainship_space_movement_enabled=true`, **`mainship_coordinate_travel_enabled=false`
  (read from the DB)**, the dock-services read surface authenticated-only / PUBLIC-denied, and the
  arbitrary-coordinate command surface authenticated-only + singular.
- **HISTORICAL PROOFS (do NOT run as current truth; left unaltered):**
  `osn-enablement-preflight.*` and `postreveal-verify.*` assert `mainship_space_movement_enabled = false`
  (the pre-enable state) and pin head `0068`; `osn-hub1a-production-catalog-verify.*` asserts the ports
  **hidden** (pre-reveal). These **fail by design** against today's production and are intentionally
  preserved as historical pre-enable / pre-reveal evidence — their flag/state assertions must NOT be inverted
  or repinned to make them pass.

## What it asserts (read-only)
One `BEGIN … REPEATABLE READ READ ONLY` + `SET LOCAL default_transaction_read_only = on` snapshot that emits
`KEY=value` lines and `ROLLBACK`s. Layers:
- **Deployment + fail-closed flag integrity:** head `0070`, none after; and for EACH of the three tracked
  keys (`mainship_send_enabled`, `mainship_space_movement_enabled`, `mainship_coordinate_travel_enabled`) the
  row exists **exactly once** and its jsonb value parses as a literal boolean. `cfg_bool()` alone is NOT used
  for the gate value because it coalesces a *missing* row to `false`, masking absence — the row-existence +
  boolean-parse guards close that. The actual stored values are read directly and reported; a value differing
  from the approved baseline is reported verbatim (`COORD_RAW`) and **fails** (never normalized or repaired).
- **Approved current baseline:** `mainship_send_enabled=true`; `mainship_space_movement_enabled=true`;
  **`mainship_coordinate_travel_enabled=false`**; zero tracked-flag config deviation.
- **Arbitrary-coordinate command surface (OSN-COORD-GATE-1):** `command_main_ship_space_move(double precision,
  double precision, uuid)` is authenticated-only (anon/PUBLIC denied); its raw coordinate writers
  (`mainship_space_begin_move`, `mainship_space_begin_move_core`) are service-role-only (auth+anon denied);
  and it is the **only** public function with identity args `(double precision, double precision, uuid)`
  executable by `authenticated` (no sibling raw-coordinate wrapper).
- **Catalog/ACL/structure (unchanged):** exactly three canonical ports active (approved identity), 0 hidden;
  the OSN command surface ACL (move-to-location authenticated; writer + dock primitive + arrival processor
  service-role-only with auth/anon denied; readiness authenticated/anon-denied); the movement-owner
  exclusivity CHECK + one-active-move indexes + receipt idempotency constraint; no fleet holding both a legacy
  and an OSN movement; the Phase-9 docked-port read surface `get_my_current_dock_services()` authenticated-only
  + PUBLIC/anon denied.
- **Authenticated boundary:** `get_world_map()` exposes exactly the three active ports (no hidden / unexpected
  starter id; only active locations); OSN readiness structurally available (≥2 active ports).

### Required verifier output block (current-state PASS)
```text
MIGRATION_HEAD=0070
MAINSHIP_SEND_ENABLED=true
MAINSHIP_SPACE_MOVEMENT_ENABLED=true
MAINSHIP_COORDINATE_TRAVEL_ENABLED=false
COORDINATE_COMMAND_PUBLIC_SURFACE=authenticated_only
COORDINATE_RAW_WRITERS_SERVICE_ROLE_ONLY=true
OSN_COORDINATE_TRAVEL_ENABLED_FRONTEND=false
OVERALL_PASS=true
```
(plus the existing `CANONICAL_STARTER_PORTS_*`, `AUTHENTICATED_MAP_PORTS_*`, `UNEXPECTED_CONFIG_CHANGES=0`,
the `PRODUCTION_OSN_*` structural markers, `DOCK_SERVICES_READ_SURFACE_*`, and `NO_PRODUCTION_WRITE_PERFORMED=true`.)

### This is a STRUCTURAL / CONFIGURATION proof only — behavioral split
This verifier does **NOT** prove a concrete live player's `osn_available=true` (that needs an anchored
authenticated session a read-only verifier cannot safely create), and it **never** emits an
`AUTHENTICATED_OSN_AVAILABLE=true`-style marker. The live player-journey behavior is proven by
**OSN-ENABLEMENT-1B**. The two are required together; neither replaces the other.

## Read-only / safety enforcement
The DB-free self-test rejects write/DDL and any **callable** reference to `reveal_starter_ports`,
`mainship_space_begin_move`, `command_main_ship_space_move`, or `mainship_space_stop` — these names appear in
the verifier ONLY inside single-quoted `to_regprocedure(...)` catalog lookups (oid resolution; cannot
execute). Connection = pinned-CA + `verify-full` + Management-API session pooler; weaker TLS / 6543 / system
CA / target overrides rejected.

## Disposable proof (`osn-postenable-verify.sh local`)
`ok[1]` expected current state passes (head 0070; flags send/space true, coordinate false; map=3; coordinate
command authenticated-only + singular; raw writers service-role-only; ACL/exclusivity/idempotency/dock-arrival
intact; behavior attributed to 1B) · `ok[2]` OSN movement flag false fails · `ok[3]` FRONTEND coordinate const
true is detected · `ok[4]` wrong active/hidden port state fails · `ok[5]` authenticated map mismatch fails ·
`ok[6]` unexpected configuration change fails · `ok[7]` write-capable verifier content rejected · **`ok[8]`
SERVER coordinate-travel flag true fails** · **`ok[9]` coordinate-flag integrity (missing row + non-boolean
value) fails** · plus the scope guard.

## Workflows
- `osn-postenable-verify.yml` — **"OSN post-enable verify (PRODUCTION — gated, read-only)"**:
  `workflow_dispatch` only, main-only, `environment: production` (human-gated), self-test gate, then the
  read-only verification. **This is the future production verification workflow and the human approval point.**
- `osn-postenable-verify-proof.yml` — disposable proof (no `environment:`). Does **not** auto-run on the
  verifier PR branch; run via `workflow_dispatch` or a `osn-coord-verify-proof-*` branch when authorized.

---

## Activation-design correction (NOT part of this verifier; flagged for a later charter)

The coordinate-travel **release state** depends on three distinct controls:

1. **`mainship_space_movement_enabled`** — base server-side OSN movement availability (DB `game_config`).
2. **`mainship_coordinate_travel_enabled`** — server-side arbitrary-coordinate authorization (DB `game_config`).
3. **`OSN_COORDINATE_TRAVEL_ENABLED`** — frontend coordinate-target UI visibility (a **compile-time
   constant**, const-folded out of the production bundle by `vite build`).

Because control (3) is a **compile-time constant** baked into a deployed bundle while control (2) is
**database-backed runtime state**, these two **cannot be flipped literally simultaneously**: a config update
takes effect instantly server-side, whereas exposing the UI requires building and deploying a new frontend.
Any release therefore has an unavoidable ordering window. This is an **activation-design issue to resolve in a
later charter**, not here. Two candidate resolutions (neither chosen or implemented in this task):

- **Runtime server-readiness signal:** make the frontend read a runtime readiness value (e.g. a catalog flag
  the server owns) instead of a compile-time constant, so a single server-side flip both authorizes the
  command and reveals the UI — eliminating the deploy-ordering window.
- **Strictly controlled staged-release protocol:** define an explicit order (e.g. ship the server gate first,
  then deploy the frontend, or vice-versa) and **document the temporary exposure/failure characteristics** of
  the in-between window (server-on/UI-off = hidden but callable; UI-on/server-off = visible but rejected with
  `coordinate_travel_disabled`).

Until that is decided, do not claim the server gate and the frontend gate can be made to change at the same
instant.

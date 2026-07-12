# TRADE-FLEET-0C — Verifier Repoint Hand-off (deploy-time human gate)

> **Status: tracking record only. No verifier file is edited by the TRADE-FLEET-0C implementation loop.**
> Recorded 2026-07-03. Running list; appended as each §2.5 site is converted.

## Design decision (planner authority; carries the reviewer caveat)

The §2.5 command-signature conversion adds a trailing `p_main_ship_id uuid default null` to seven
main-ship RPCs (drop + recreate — the added arg changes each function's identity `fn()` → `fn(uuid)`).
This is **backward compatible at runtime** (zero-arg callers → default null → sole-ship shim), but it
**invalidates any verifier pin that resolves those functions by their exact zero-arg signature** against a
0C-applied database.

Two classes of verifier pin those functions by signature:

1. **The PORT-ENTRY-1 production gate** (`scripts/port-entry-1-production-verify.{sql,sh}`) — its D2
   exact-RPC inventory lists each RPC as a `regprocedure` literal.
2. **The dispatch-only OSN3 / PORT-LAUNCH / OSN-enable realchain-perm, live-check, and postenable
   verifiers** — they pin pre-0C signatures via `::regprocedure`, `to_regprocedure('public.fn()')`,
   `has_function_privilege(role,'public.fn()','EXECUTE')`, `pronargs`, and descriptor (`ARGS`) checks.

**Both classes are FROZEN exactly like the PORT-ENTRY gate.** They truthfully describe the **deployed
production surface (migration head 0072)**, which this loop does not change. They are **repointed at the
deploy-time human gate**, not by this loop (out of locked scope). The **post-0C surface** (new
`(…, uuid)` signatures, `commission_additional_main_ship`, per-ship idempotency, the §2.7 eight
properties) is proven by the **forthcoming TRADE-FLEET verifier**. This document is the hand-off list so
**no pin is lost** at the deploy gate.

### What does NOT need repointing (recorded so the gate does not over-edit)

- **Zero-arg CALLS** (`v := public.fn();`, `perform public.fn();`, `authrpc "public.fn()"`,
  `.rpc('repair_main_ship', {})`): still resolve via the default param — **unchanged**.
- **Name-only surface lists** (`array['…','repair_main_ship',…]`, `EXPECT_AUTH_SURFACE="…"`,
  `surface.names='…'`, `VALUES ('repair_main_ship')`): compare by `proname`, which is unchanged by a
  defaulted arg — **unchanged** (the drop+recreate makes exactly one function of that name; no overload).
- **Greps of a FROZEN migration file** (e.g. `grep 'create or replace function public.fn()' "$MIG"`
  where `$MIG` is 0068/0069/0071): read the unedited pre-0C migration text — **unchanged**.

Only **signature-resolving** pins (regprocedure / `to_regprocedure` / `has_function_privilege('…()')` /
`pronargs=0` / descriptor `ARGS=''`) break against a 0C DB and appear in the tables below.

---

## Invalidated signature pins — repoint `fn()` → `fn(uuid)`

### #6 `repair_main_ship()` → `repair_main_ship(uuid)`  *(converted in migration 0081)*

| file:line | pinned expression | repoint to |
|---|---|---|
| `scripts/port-entry-1-production-verify.sql:102` | `('public.repair_main_ship()')` (D2 exact-RPC inventory) | `('public.repair_main_ship(uuid)')` |
| `scripts/osn3-s5-live-check.sh:92` | `has_function_privilege('authenticated','public.repair_main_ship()'::regprocedure,'EXECUTE')` | `…repair_main_ship(uuid)…` |
| `scripts/osn3-s5-realchain-perm.sql:80` | `has_function_privilege('authenticated','public.repair_main_ship()'::regprocedure,'EXECUTE')` | `…repair_main_ship(uuid)…` |
| `scripts/osn3-s6a-live-check.sh:94` | `has_function_privilege('authenticated','public.repair_main_ship()'::regprocedure,'EXECUTE')` | `…repair_main_ship(uuid)…` |
| `scripts/osn3-s6a-realchain-perm.sql:66` | `has_function_privilege('authenticated','public.repair_main_ship()'::regprocedure,'EXECUTE')` | `…repair_main_ship(uuid)…` |

*Not invalidated (recorded): zero-arg calls `osn3-anchor1a-realchain-fixtures.sql:242`,
`osn3-s5-realchain-fixtures.sql:226`, `scripts/verify-mainship-repair.mjs:117,125` (`.rpc('repair_main_ship', {})`);
name-only lists in `osn-hub1a-production-catalog-verify.{sql:101,sh:36}`, `osn-hub1a-realchain-perm.sql:88`,
`osn3-s2/s3/s4/s5/s6a-*` expected arrays, `portlaunch1a-realchain-perm.sql:53`, `osn3-legacy-send-live-check.sh:68`.*

### #4 `get_my_current_dock_services()` → `get_my_current_dock_services(uuid)`  *(converted in migration 0082)*

| file:line | pinned expression | repoint to |
|---|---|---|
| `scripts/port-entry-1-production-verify.sql:107` | `('public.get_my_current_dock_services()')` (D2 exact-RPC inventory) | `('public.get_my_current_dock_services(uuid)')` |
| `scripts/osn-postenable-verify.sql:107-108` | `to_regprocedure('public.get_my_current_dock_services()')` + `has_function_privilege(…, ::oid,'EXECUTE')` (ACL_DOCK_AUTH) | `…get_my_current_dock_services(uuid)…` |
| `scripts/osn-postenable-verify.sql:109-110` | `to_regprocedure('public.get_my_current_dock_services()')` (ACL_DOCK_ANON_DENIED) | `…get_my_current_dock_services(uuid)…` |
| `scripts/phase9-dock-services-proof.sh:67` | `has_function_privilege('anon','public.get_my_current_dock_services()','EXECUTE')` | `…get_my_current_dock_services(uuid)…` |
| `scripts/phase9-dock-services-proof.sh:68` | `has_function_privilege('authenticated','public.get_my_current_dock_services()','EXECUTE')` | `…get_my_current_dock_services(uuid)…` |
| `scripts/phase9-dock-services-proof.sh:73` | `pronargs from pg_proc where proname='get_my_current_dock_services'` expects `0` | expects `1` (one defaulted arg) |

*Not invalidated (recorded): `phase9-dock-services-proof.sh:21,26,27` grep the frozen 0069 `$MIG` text;
zero-arg calls `phase9-dock-services-proof.sh:42,44`.*

### #5 `get_osn_movement_readiness()` → `get_osn_movement_readiness(uuid)`  *(converted in migration 0082)*

| file:line | pinned expression | repoint to |
|---|---|---|
| `scripts/port-entry-1-production-verify.sql:99` | `('public.get_osn_movement_readiness()')` (D2 exact-RPC inventory) | `('public.get_osn_movement_readiness(uuid)')` |
| `scripts/osn-enable-operation.sql:72` | `to_regprocedure('public.get_osn_movement_readiness()') is not null` | `…get_osn_movement_readiness(uuid)…` |
| `scripts/osn-enablement-preflight.sql:110` | `to_regprocedure('public.get_osn_movement_readiness()') as readiness_fn` | `…get_osn_movement_readiness(uuid)…` |
| `scripts/osn-coord-enable-1b-readiness-proof.sql:182,184,186` | `has_function_privilege('anon'/'public'/'authenticated','public.get_osn_movement_readiness()','EXECUTE')` | `…get_osn_movement_readiness(uuid)…` |
| `scripts/osn-postenable-verify.sql:97-100` | `to_regprocedure('public.get_osn_movement_readiness()')` (ACL_READINESS_AUTH / ANON_DENIED) | `…get_osn_movement_readiness(uuid)…` |
| `scripts/osn-postenable-verify.sql:127-130,135` | `to_regprocedure('public.get_osn_movement_readiness()')` (RDN_RESOLVED / RETTYPE / SECDEF / SEARCHPATH descriptor probes) | `…get_osn_movement_readiness(uuid)…` |
| `scripts/osn-hub1a-production-catalog-verify.sql:156,167` | `('readiness','public.get_osn_movement_readiness()')` (regprocedure descriptor + prosrc-identity) | `('readiness','public.get_osn_movement_readiness(uuid)')` |
| `scripts/osn-hub1a-production-catalog-verify.sh:146` | `D_readiness_ARGS = ""` (expects empty arg list) | expects `uuid` |
| `scripts/portlaunch1a-realchain-perm.sql:35` | `p.oid = 'public.get_osn_movement_readiness()'::regprocedure` | `…get_osn_movement_readiness(uuid)::regprocedure` |
| `scripts/portlaunch1a-realchain-perm.sql:39,41` | `has_function_privilege('authenticated'/'anon','public.get_osn_movement_readiness()','EXECUTE')` | `…get_osn_movement_readiness(uuid)…` |

*Not invalidated (recorded): zero-arg calls in `osn-coord-enable-1b-readiness-proof.sql:91,144,168,206,208`,
`osn-enablement-1b-journey.sh:128`, `osn-postenable-verify.sql:120`, `port-entry-1-production-verify.sql:142,144`,
`portlaunch1a-realchain-fixtures.sql:*`, `portlaunch2b-realchain-fixtures.sql:172`; the greps of frozen
migration files `osn-coord-enable-1b-readiness-proof.sh:19,29,30` (0071 `$MIG`),
`osn-hub1a-production-catalog-verify.sh:97,98` (MIG68); name-only surface lists
`osn-enablement-preflight.sql:145`, `osn-hub1a-production-catalog-verify.{sql:101,sh:36}`,
`osn-hub1a-realchain-perm.sql:87`, `osn3-dock0-realchain-perm.sql:60`, `portlaunch1a-realchain-perm.sql:52`.*

### #2 `command_main_ship_space_stop(uuid)` → `command_main_ship_space_stop(uuid, uuid)`  *(converted in migration 0083)*

| file:line | pinned expression | repoint to |
|---|---|---|
| `scripts/port-entry-1-production-verify.sql:105` | `('public.command_main_ship_space_stop(uuid)')` (D2 exact-RPC inventory) | `('public.command_main_ship_space_stop(uuid, uuid)')` |
| `scripts/osn-enablement-preflight.sql:43` | `to_regprocedure('public.command_main_ship_space_stop(uuid)')` (stop_wrapper) | `…command_main_ship_space_stop(uuid,uuid)…` |
| `scripts/osn3-osn4-realchain-perm.sql:13` | `has_function_privilege('authenticated','public.command_main_ship_space_stop(uuid)','EXECUTE')` | `…command_main_ship_space_stop(uuid,uuid)…` |

### #3 `command_main_ship_space_move_to_location(uuid, uuid)` → `(uuid, uuid, uuid)`  *(converted in migration 0083)*

| file:line | pinned expression | repoint to |
|---|---|---|
| `scripts/port-entry-1-production-verify.sql:106` | `('public.command_main_ship_space_move_to_location(uuid, uuid)')` (D2 exact-RPC inventory) | `('public.command_main_ship_space_move_to_location(uuid, uuid, uuid)')` |
| `scripts/osn-enable-operation.sql:71` | `to_regprocedure('public.command_main_ship_space_move_to_location(uuid,uuid)') is not null` | `…(uuid,uuid,uuid)…` |
| `scripts/osn-enablement-preflight.sql:109` | `to_regprocedure('public.command_main_ship_space_move_to_location(uuid,uuid)')` (move_to_loc_wrapper) | `…(uuid,uuid,uuid)…` |
| `scripts/osn-hub1a-production-catalog-verify.sql:154,165` | `('cmd','public.command_main_ship_space_move_to_location(uuid,uuid)')` (regprocedure descriptor + prosrc-identity) | `…(uuid,uuid,uuid)…` |
| `scripts/osn-hub1a-realchain-perm.sql:30` | `to_regprocedure('public.command_main_ship_space_move_to_location(uuid,uuid)')` (v_wrapper) | `…(uuid,uuid,uuid)…` |
| `scripts/osn-postenable-verify.sql:88,89` | `to_regprocedure('public.command_main_ship_space_move_to_location(uuid,uuid)')` (ACL_MOVE_TO_LOC_AUTH) | `…(uuid,uuid,uuid)…` |

*Not invalidated (recorded): zero-arg-shape calls resolve by arg types and still match the leading params via
default — but the pins above resolve the EXACT arg list and must repoint. Live CALLs like
`osn-coord-gate-proof.sh:82` / `osn-enablement-1b-journey.sh:79…` pass `(location, request_id)` positionally
→ still resolve via the trailing default; NOT invalidated. Name-only lists
(`osn-hub1a-production-catalog-verify.sql:101`, `EXPECT_AUTH_SURFACE`) unchanged.*

### #1 `command_main_ship_space_move(double precision, double precision, uuid)` → `(double precision, double precision, uuid, uuid)`  *(converted in migration 0178 — COORD-GUARD, the coordinate-enable slice this section deferred to)*

**Was deferred in 0C (dark coordinate command; §2.5 [C] row)** because it rejected at `…0070…:57`
(`mainship_coordinate_travel_enabled = false`) before its ship read. Multi-ship commissioning went LIVE
2026-07-12, so ahead of the coordinate-travel flip, **migration
`20260618000178_coord_guard_a0fix.sql`** applied the same trailing `p_main_ship_id uuid default null` +
`mainship_resolve_owned_ship` conversion (drop + recreate; the flip script
`scripts/activate-coordinate-travel.{sql,sh}` preconditions on the guarded prosrc). Backward compatible at
runtime (pre-slice clients send `{p_target_x, p_target_y, p_request_id}` → default null → sole-ship shim;
the same slice ships the client passthrough — the S6C wrapper now also sends the selected/sole
`p_main_ship_id`, like its stop/settle/readiness siblings), but the previously-recorded "pins that remain
valid" now break and repoint at the deploy-time human gate:

| file:line | pinned expression | repoint to |
|---|---|---|
| `scripts/port-entry-1-production-verify.sql:104` | `('public.command_main_ship_space_move(double precision, double precision, uuid)')` (D2 exact-RPC inventory) | `('public.command_main_ship_space_move(double precision, double precision, uuid, uuid)')` |
| `scripts/port-entry-1-production-verify.sql:141` | `to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)')` (COORD_CMD_PRESENT) | `…(double precision,double precision,uuid,uuid)…` |
| `scripts/osn-postenable-verify.sql:148,151,154,157,162` | `to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)')` (COORD_CMD_RESOLVED / SECDEF / ACL / prosrc descriptor probes) | `…(double precision,double precision,uuid,uuid)…` |
| `scripts/osn-postenable-verify.sh:173` | greps its own SQL for the 3-arg `to_regprocedure` literal (frozen-pair self-check) | the 4-arg literal, together with the .sql repoint |
| `scripts/osn-enablement-preflight.sql:42` | `to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)') as move_wrapper` | `…(double precision,double precision,uuid,uuid)…` |
| `scripts/osn-coord-gate-proof.sh:52,53` | `has_function_privilege('anon'/'authenticated','public.command_main_ship_space_move(double precision, double precision, uuid)','EXECUTE')` | `…(double precision, double precision, uuid, uuid)…` |
| `scripts/osn-postenable-verify.sql:176-181` | `COORD_SURFACE_COUNT` — census by **arg-type OIDs**, not display string: counts public authenticated-executable normal functions with `p.pronargs=3` and `proargtypes[0..2]` = (`float8`,`float8`,`uuid`); expects exactly 1 | `p.pronargs=4` + add `AND p.proargtypes[3] = 'uuid'::regtype::oid`; still expects exactly 1. Consumers `osn-postenable-verify.sh:89` (`ck … COORD_SURFACE_COUNT … 1`) and `:135` (the `COORDINATE_COMMAND_PUBLIC_SURFACE` composite) keep their `=1` expectation once the .sql census is repointed — update the .sh's descriptive text "(float8,float8,uuid)" alongside |
| `scripts/osn3-s6a-realchain-perm.sql:28` **and** `:34` | `:28` exact identity-args assert: `r.args <> 'p_target_x double precision, p_target_y double precision, p_request_id uuid'`; `:34` **SECURITY-INTENT assert** `if r.args ~* 'player' or r.args ~* 'ship'` ("wrapper accepts no player/ship id") — the `'ship'` half is now **deliberately false** under 0178 | `:28` → append `, p_main_ship_id uuid` (`pg_get_function_identity_arguments` omits defaults). `:34` → **SEMANTIC rewrite, not a literal swap**: keep the `~* 'player'` reject verbatim; replace the `~* 'ship'` reject with an assert that the ONLY ship-matching arg is the TRAILING defaulted `p_main_ship_id` (ownership-resolved server-side via `mainship_resolve_owned_ship` — the 0178 contract). The repointed `:28` exact-args string already pins that shape; `:34` keeps player-id rejection as its own teeth. (The `:37` "PERM ok … no player/ship id param" notice string is cosmetic — update alongside.) |
| `scripts/osn3-s6a-live-check.sh:62,65` | the SAME two asserts run against **live prod** (manual-dispatch workflow): `:62` exact identity-args string, `:65` `r.args ~* 'player' or r.args ~* 'ship'` | same repoint as the realchain-perm row: `:62` → the 4-arg identity string; `:65` → the semantic rewrite (`'player'` absent; the sole ship arg is the trailing ownership-resolved `p_main_ship_id`) |

*Not invalidated (recorded): the client `.rpc('command_main_ship_space_move', {p_target_x,…})` named-arg
calls (which as of this slice ALSO pass `p_main_ship_id` — matching the new signature either way) and any
name-only surface lists resolve via named args / `proname` — unchanged. The prosrc md5 story: no verifier
pins this function's prosrc md5 (the osn-postenable probes are token/descriptor checks), so no md5
re-derivation is needed; the 0178 body differs from 0070 by exactly the step-3 resolver swap
(diff-verified in the slice).*

### #7 `normalize_main_ship_dock()` → `normalize_main_ship_dock(uuid)`  *(converted in migration 0084)*

| file:line | pinned expression | repoint to |
|---|---|---|
| `scripts/port-entry-1-production-verify.sql:109` | `('public.normalize_main_ship_dock()')` (D2 exact-RPC inventory) | `('public.normalize_main_ship_dock(uuid)')` |
| `scripts/port-entry-1-production-verify.sql:47-52` | `to_regprocedure('public.normalize_main_ship_dock()')` (N_RESOLVED / N_RET_JSONB / N_PLPGSQL / N_SECDEF / N_SEARCHPATH / N_OWNER descriptor probes) | `…normalize_main_ship_dock(uuid)…` |
| `scripts/port-entry-1-production-verify.sql:53` | `md5(p.prosrc)=:'exp_normalize'` (N_PROSRC_OK — **prosrc md5 pin**; body changed by 0C) | re-derive md5 from the 0C body |
| `scripts/port-entry-1-production-verify.sql:67-70` | `to_regprocedure('public.normalize_main_ship_dock()')` (ACL_N_PUBLIC/ANON/AUTH/SVC) | `…normalize_main_ship_dock(uuid)…` |
| `scripts/port-entry-1-production-verify.sh:41` | `extract_prosrc_md5 "$MIG" 'create or replace function public.normalize_main_ship_dock()'` (EXP_N — **md5 pin derivation**) | re-derive from the 0C `normalize_main_ship_dock(p_main_ship_id uuid default null)` body |
| `scripts/port-entry-1-production-verify.sh:171` | greps SQL for `('public.normalize_main_ship_dock()')` inventory line | `('public.normalize_main_ship_dock(uuid)')` |
| `scripts/port-entry-1-proof.sql:275,276` | `has_function_privilege(…,'public.normalize_main_ship_dock()','EXECUTE')` | `…normalize_main_ship_dock(uuid)…` |
| `scripts/port-entry-1-proof.sql:281` | `'public.normalize_main_ship_dock()'::regprocedure` (prosecdef probe) | `…normalize_main_ship_dock(uuid)::regprocedure` |

*Not invalidated (recorded): zero-arg CALLs `port-entry-1-proof.sql:169,178,196,209,226,249`
(`call_as(u,'public.normalize_main_ship_dock()')`) resolve via the trailing default → unchanged.*

### prosrc md5-pin repoints (PORT-ENTRY three pinned bodies)

The PORT-ENTRY verifier pins the raw prosrc md5 of three bodies (`port_entry_commission_writer`,
`commission_first_main_ship`, `normalize_main_ship_dock`). TRADE-FLEET-0C changed **two** of them, so their
md5 pins are invalidated against a 0C-applied DB and must be **re-derived at the deploy-time human gate**:

- **`port_entry_commission_writer`** — body changed by 0C (0077 added `cargo_capacity_m3`; 0078 advisory-lock
  reframe; 0080 delegates to `port_entry_commission_build`). → **re-derive md5.**
- **`normalize_main_ship_dock`** — body changed by 0C (0084 §2.5 resolver swap + `(uuid)` signature). →
  **re-derive md5.**
- **`commission_first_main_ship`** — **NOT changed by 0C** (its zero-ship pre-check + created-flag
  interpretation still work). → **its md5 pin remains VALID; no repoint.**

---

## Abstract cargo columns — NOT dropped in 0C (defer to TRADE-UI-1)

**Design decision (planner authority, refines §2.3).** The abstract cargo columns are **not physically
dropped in 0C.** The frontend still `SELECT`s and displays `cargo_capacity` (instance) and
`base_cargo_capacity` (hull) — `src/features/map/mainshipApi.ts:29/40/51/62`,
`src/features/…/MainShipPreview.tsx:130/192`, `useGalaxyMapData.ts:26/66` — so dropping them would break
live ship/galaxy reads, and the fix touches `src/` (TRADE-UI-1 scope; 0C must not touch `src/`). Therefore
in 0C the **volume model** (`cargo_capacity_m3`, `ship_cargo_lots` lot-sum) is the **authoritative** capacity
source for new trade paths, while the abstract `cargo_capacity` / `base_cargo_capacity` / `cargo_used`
columns **remain as coexisting legacy** (still populated, still read by the current UI). The physical column
drop + frontend swap to the volume model land **together in TRADE-UI-1.**

## New TRADE-FLEET-0C proof harness (§2.7)

`scripts/trade-fleet-0c-proof.{sql,sh}` — a write-then-**ROLLBACK** real-chain proof (house idiom of
`port-entry-1-proof.{sql,sh}`), with a DB-free `selftest`. It proves the **0C-established** subset of the
§2.7 eight properties: provisioning via the real RPCs + the dark/cap/flag gate;
**(1)** N-ship coexistence; **(2)** independent per-ship movement (explicit `p_main_ship_id`, per-ship receipt
scoping); **(7)** legacy one-ship shim validity (+ multi-ship ambiguity fails closed). It enables
`mainship_additional_commission_enabled` **only inside the rolled-back txn** (production flag stays false).
The **two trade-enforcement properties** — volume-capacity-check-on-write and docked-trade-while-in-transit
concurrency — are **DEFERRED to TRADE-MARKET-1's verifier** (no buy/sell RPC exists yet). The live/ephemeral
run is the CI/human gate; the DB-free selftest runs in-loop. It is invoked directly
(`bash scripts/trade-fleet-0c-proof.sh selftest`), matching the house convention for `.sh` proofs (not wired
into `package.json` or any auto-run/CI dispatch — dispatch stays a human gate).

## §2.7 "other verifiers" audit — all PASS UNCHANGED (inspection-based; no local DB)

Audited each named `.mjs` verifier/helper against the exact 0C deltas: (a) `player_id UNIQUE` dropped;
(b) new NOT NULL `>0` `cargo_capacity_m3`/`base_cargo_capacity_m3`; (c) abstract `cargo_used`/`cargo_capacity`/
`base_cargo_capacity` **kept**; (d) six commands now take a trailing `p_main_ship_id uuid default null`
(zero-arg/positional calls resolve via the sole-ship shim); (e) `ensure_main_ship_for_player` + commission
writers now populate `cargo_capacity_m3`. A verifier BREAKS only if it asserts the dropped UNIQUE, hard-pins a
converted zero-arg signature (`::regprocedure`/`pronargs`), **service-role**-inserts a ship/hull row without the
new NOT NULL columns, or depends on removed behavior. **None do.**

| verifier / helper | provisioning / relevant surface | verdict | reason |
|---|---|---|---|
| `verify-phase7.mjs` | `admin.rpc('ensure_main_ship_for_player')`; reads `cargo_capacity`/`cargo_used` (abstract, kept); two **client** inserts of ship/hull rows | **PASSES unchanged** | ensure now populates `cargo_capacity_m3`; abstract cols kept & read; the two direct inserts are **client** (authenticated) writes that are permission/RLS-denied **before** any NOT NULL check — and the test only asserts denial / no-mutation (`void ci`), not the specific error. No UNIQUE/regproc pin. |
| `verify-phase8.mjs` | `ensure_main_ship_for_player`; `calculate_expedition_stats(p_main_ship_id,…)` (already ship-addressed, [N]); reads abstract `cargo_capacity` | **PASSES unchanged** | ensure populates volume col; abstract cols kept & read; stat adapter unchanged and already takes `p_main_ship_id`. No direct insert. |
| `verify-mainship-move.mjs` | `ensure_main_ship_for_player`; `move_main_ship_to_location`/`send_main_ship_expedition`/`request_main_ship_return` ([N], unchanged); `dev_set_main_ship_destroyed` | **PASSES unchanged** | all provisioning/commands via unchanged/[N] RPCs by name; no direct ship insert; no UNIQUE/regproc. |
| `verify-mainship-preview.mjs` | `ensure_main_ship_for_player`; `calculate_expedition_stats` (ship-addressed) | **PASSES unchanged** | ensure populates volume col; adapter ship-addressed; no direct insert. |
| `verify-mainship-repair.mjs` | `ensure_main_ship_for_player`; `rpc('repair_main_ship', {})` (name-based, empty args) | **PASSES unchanged** | `repair_main_ship({})` resolves to the new `repair_main_ship(p_main_ship_id default null)` via all-defaults + the sole-ship shim (player has exactly one ship). Backward compatible. |
| `verify-mainship-send.mjs` | `ensure_main_ship_for_player`; `send_main_ship_expedition`/`request_main_ship_return`/`process_mainship_expeditions` ([N]) | **PASSES unchanged** | unchanged/[N] RPCs by name; abstract-col reads intact; no direct insert. |
| `verify-mainship-teardown-unit.mjs` | **mock-admin unit test** (no DB); tests teardown/flag-restore logic | **PASSES unchanged** | pure in-process unit test; touches no ship schema at all. |
| `dev-commission-mainship.mjs` | `rpc('ensure_main_ship_for_player')` + GET display | **PASSES unchanged** | provisions via ensure (populates volume col). *(Non-breaking observation: a header comment still says "player_id is UNIQUE with on-conflict-do-nothing" — now stale after 0C's advisory-lock reframe; left untouched as it is a comment, not an assertion, and does not affect behavior.)* |
| `dev-grant-ships.mjs` | grants **`base_units`** (scout/corvette/frigate) | **PASSES unchanged** | despite the name, it never touches `main_ship_instances`/`main_ship_hull_types`; unaffected by 0C. |
| `dev-destroy-mainship.mjs` | `rpc('dev_set_main_ship_destroyed')` + GET display | **PASSES unchanged** | canonical destroy RPC (unchanged); no ship insert. |
| `dev-clean-test-users.mjs` | deletes `auth.users` (FK cascade) | **PASSES unchanged** | deletes users only; no ship schema dependency. |
| `cleanup-m45-orphans.mjs`, `db-cleanup.mjs`, `verify-cleanup.mjs` | combat/movement runtime retention cleanup | **PASSES unchanged** | no `main_ship_*` insert, no UNIQUE/regproc pin; unrelated to 0C schema. |
| `dev-mainship-flag.mjs`, `dev-mainship-space-movement-flag.mjs` | `game_config` flag toggles | **PASSES unchanged** | flag helpers; no ship insert; do not touch the additional-commission flag's committed value. |

**Why they stay green:** the 0C design is deliberately **backward-compatible** — abstract columns are **kept**
(so legacy reads keep working), the six commands gained **defaulted trailing params** (so name-based / positional
`rpc()` calls resolve via the sole-ship shim), and `ensure_main_ship_for_player` + the commission writers now
**populate `cargo_capacity_m3`** (so RPC-based provisioning satisfies the new NOT NULL column). Verified within
the **audited named set** (the `.mjs` verifiers/helpers listed above): the only direct `main_ship_*` table inserts
among them are the two **client** RLS-deny probes in `verify-phase7.mjs` (lines 67, 91 — authenticated role, denied
before the NOT NULL check), so none of the audited verifiers/helpers hit the new constraint. **No verifier or
helper was edited.**

> **Scope note (do not over-read):** this "audited named set" is the §2.7 clause's scope only. It is **not** the
> whole `scripts/` tree — the dispatch-only realchain/proof fixtures **do** contain direct
> `main_ship_instances` inserts that omit `cargo_capacity_m3`; that separate break-class is tracked in the next
> section for the deploy-time gate.

The deeper 0C-specific assertions — the **volume shape** (`cargo_capacity_m3` populated/authoritative), **selected-ship**
targeting (explicit `p_main_ship_id`), and **N-ship** coexistence/cap — are proven by the new
`scripts/trade-fleet-0c-proof.{sql,sh}` harness (which self-provisions N ships), **not** by retrofitting every legacy
single-ship verifier. The live-DB runs of all these verifiers remain the human/CI gate.

## NOT-NULL direct-insert break-class — dispatch-only realchain/proof fixtures (deploy-time repoint)

Beyond the signature-pin repoints above, 0C introduces a **second, distinct break-class** for the frozen
dispatch-only fixtures: migration **0076/0077** added `main_ship_instances.cargo_capacity_m3` as **NOT NULL `> 0`**.
Many realchain/proof fixtures **service-role / SQL-context insert `main_ship_instances` rows directly** with an
explicit column list that predates 0C and therefore **omits `cargo_capacity_m3`**. Against a full `0001..0084`
chain, **every such insert violates the new NOT NULL constraint** — a different mechanism from the `::regprocedure`
signature pins (this is a column-list break, not a signature break).

**Sweep result (verified across the whole `scripts/` tree):** **100** direct `main_ship_instances` inserts omit
`cargo_capacity_m3`, across **22 files**. (There are **no** service-role `main_ship_hull_types` inserts in
`scripts/` — the only hull insert is the client RLS-deny probe in `verify-phase7.mjs:67-68` — so the
`base_cargo_capacity_m3` NOT NULL break-class does **not** arise here; only `cargo_capacity_m3`.)

**Repoint at the deploy-time human gate:** add `cargo_capacity_m3` (e.g. the hull's `base_cargo_capacity_m3`, or a
literal such as `50.0` matching the co-inserted abstract `cargo_capacity`) to each insert's column + value lists.
These files are **frozen dispatch-only gates — NOT edited by this loop** (same policy as the signature-pin
repoints). Captured here so no fixture is lost at the gate.

| file | # inserts to repoint |
|---|---|
| `scripts/osn3-s3-realchain-fixtures.sql` | 15 |
| `scripts/osn3-s2-realchain-fixtures.sql` | 13 |
| `scripts/osn3-s5-realchain-fixtures.sql` | 10 |
| `scripts/osn3-s4-realchain-fixtures.sql` | 9 |
| `scripts/osn3-s2-transition-core-proof.sql` | 9 |
| `scripts/osn3-s6a-realchain-fixtures.sql` | 6 |
| `scripts/osn3-anchor1a-realchain-fixtures.sql` | 6 |
| `scripts/port-entry-1-proof.sql` | 5 |
| `scripts/osn-hub1a-realchain-fixtures.sql` | 5 |
| `scripts/osn3-s1-trigger-proof.sql` | 4 |
| `scripts/phase9-dock-services-proof.sh` | 3 |
| `scripts/osn3-osn4-realchain-fixtures.sql` | 3 |
| `scripts/osn3-s3-realchain-concurrency.sh` | 2 |
| `scripts/osn3-dock0-realchain-fixtures.sql` | 2 |
| `scripts/osn3-s5-realchain-concurrency.sh` | 1 |
| `scripts/osn3-s4-realchain-concurrency.sh` | 1 |
| `scripts/osn3-s2-realchain-lockorder.sh` | 1 |
| `scripts/osn3-s1-schema-proof.sql` | 1 |
| `scripts/osn-hub1a-realchain-stop-timestamp-race.sh` | 1 |
| `scripts/osn-hub1a-realchain-stop-race.sh` | 1 |
| `scripts/osn-enablement-1b-journey.sh` | 1 |
| `scripts/osn-coord-gate-proof.sh` | 1 |

**Per-file caveat for the gate owner:** most of these inserts already supply the abstract `cargo_capacity` (e.g. `50`)
and only need `cargo_capacity_m3` added. A subset — `osn3-s1-schema-proof.sql`, `osn3-s1-trigger-proof.sql`,
`osn3-s2-transition-core-proof.sql` — use **minimal/partial** column lists (e.g. `(player_id, status, spatial_state)`
or `(main_ship_id, player_id, status, spatial_state)`) that exercise the spatial-state constraints/triggers; the gate
owner should confirm each proof's chain context and add `cargo_capacity_m3` (and any other now-required column)
per file. Note these same fixtures may also depend on the dropped `player_id UNIQUE` (some insert two ships for one
player) — assess alongside the repoint. **The `trade-fleet-0c-proof` harness deliberately provisions via the real
RPCs precisely to avoid this direct-insert fragility.**

## TRADE-MARKET-1 proof harness

`scripts/trade-market-1-proof.{sql,sh}` — a write-then-**ROLLBACK** real-chain proof (same house idiom as
`trade-fleet-0c-proof.{sql,sh}`), with a DB-free `selftest`. It proves the atomic trade surface + the priced
add-ship debit across nine properties: **P0** dark gate (offers/buy/sell reject `trade_market_disabled`, zero
writes), **P1** `get_market_offers` (docked → 6 Haven offers; in-transit → `not_docked`), **P2** buy atomic
(one lot + one receipt + wallet debit), **P3** buy idempotency, **P4** volume check (`insufficient_volume`),
**P5** credit check (`insufficient_credits`), **P6** sell FIFO margin (oldest-lot-first, `realized_margin =
total_price − cost_basis_consumed`), **P7** sell idempotency + `insufficient_cargo`, **P8** priced add-ship §1b
(funded debits `main_ship_price`; too-poor → `insufficient_credits` with no ship/debit; first ship free). It
enables `trade_market_enabled` + `mainship_additional_commission_enabled` (and mirrors `reveal_starter_ports` +
`mainship_space_movement_enabled`, and transiently perturbs an offer price for the FIFO test) **only inside the
rolled-back txn** — the committed/production flag values stay false, and it persists no wallet/lot/receipt/ship/
flag flip. Wallets are funded by a direct owner `insert into player_wallet` (rolled back). Invoked directly
(`bash scripts/trade-market-1-proof.sh selftest`), matching the house convention for `.sh` proofs — **not** wired
into `package.json` or any auto-run/CI dispatch (dispatch stays a human gate). The live/ephemeral run is the CI
gate; the DB-free selftest runs in-loop.

## §2.5 command-signature conversion — **COMPLETE**

Six active sites converted to a trailing `p_main_ship_id uuid default null` via the shared
`mainship_resolve_owned_ship` helper: **#2** `command_main_ship_space_stop`, **#3**
`command_main_ship_space_move_to_location`, **#4** `get_my_current_dock_services`, **#5**
`get_osn_movement_readiness`, **#6** `repair_main_ship`, **#7** `normalize_main_ship_dock`. **#1**
`command_main_ship_space_move` was deferred/dark in 0C and has since been **converted by migration 0178**
(COORD-GUARD, 2026-07-12 — see its updated §#1 table above for the pins that now repoint). All backward
compatible (zero-arg callers → default null → sole-ship shim). Every
pin above is a **deploy-time human repoint**, out of the loop's locked scope; the post-0C surface is proven
by the forthcoming TRADE-FLEET verifier. The PORT-ENTRY D2 inventory
(`scripts/port-entry-1-production-verify.sql:96-113`) stays frozen and is repointed wholesale at the deploy
gate.

---

## A0 FOUNDATION FIXUP — two additional owned-ship conversions (migration 0159)

Pre-team-command audit. The same trailing `p_main_ship_id uuid default null` + `mainship_resolve_owned_ship`
conversion applied to two SECURITY DEFINER reads that were still written with the unguarded sole-ship
derivation `... from main_ship_instances where player_id = auth.uid()` — a real arbitrary-ship bug once a
player owns >1 ship. Backward compatible (existing zero-/two-arg callers → default null → sole-ship shim);
DARK (multi-ship still off). Post-0C surface proven by the forthcoming TRADE-FLEET verifier; both pins below
are a **deploy-time human repoint**, out of this fixup's locked scope.

### `get_my_expedition_preview(jsonb, text)` → `get_my_expedition_preview(jsonb, text, uuid)`  *(migration 0159)*

| file:line | pinned expression | repoint to |
|---|---|---|
| `scripts/port-entry-1-production-verify.sql:98` | `('public.get_my_expedition_preview(jsonb, text)')` (D2 exact-RPC inventory) | `('public.get_my_expedition_preview(jsonb, text, uuid)')` |

### `get_my_docked_store()` → `get_my_docked_store(uuid)`  *(migration 0159)*

**No signature-resolving pin — nothing to repoint.** The only reference is a ZERO-ARG call
(`scripts/verify-station-storage.mjs:91` — `rpc('get_my_docked_store')`), which still resolves via the default
param (per the "Zero-arg CALLS" rule above). `get_my_docked_store` was added in migration 0158, after the 0072
freeze, so it is not in the PORT-ENTRY D2 inventory at all.

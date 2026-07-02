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

### #1 `command_main_ship_space_move(double precision, double precision, uuid)` — **NOT converted in 0C**

**Deferred (dark coordinate command; §2.5 [C] row).** It rejects at `…0070…:57`
(`mainship_coordinate_travel_enabled = false`) before its ship read, so its single-ship derivation is
unreachable while dark. **Its signature is unchanged → no pin for it breaks → no repoint needed.** The
future coordinate-enable slice owns ship-scoping it. Pins that remain valid (recorded for completeness):
`port-entry-1-production-verify.sql:104,141`, `osn-postenable-verify.sh:84-86`,
`osn-enablement-preflight.sql:42`, `osn-coord-gate-proof.sh:52,53`.

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

## §2.5 command-signature conversion — **COMPLETE**

Six active sites converted to a trailing `p_main_ship_id uuid default null` via the shared
`mainship_resolve_owned_ship` helper: **#2** `command_main_ship_space_stop`, **#3**
`command_main_ship_space_move_to_location`, **#4** `get_my_current_dock_services`, **#5**
`get_osn_movement_readiness`, **#6** `repair_main_ship`, **#7** `normalize_main_ship_dock`. **#1**
`command_main_ship_space_move` is **deferred/dark** (coordinate gate rejects before any ship read; signature
unchanged → no repoint). All backward compatible (zero-arg callers → default null → sole-ship shim). Every
pin above is a **deploy-time human repoint**, out of the loop's locked scope; the post-0C surface is proven
by the forthcoming TRADE-FLEET verifier. The PORT-ENTRY D2 inventory
(`scripts/port-entry-1-production-verify.sql:96-113`) stays frozen and is repointed wholesale at the deploy
gate.

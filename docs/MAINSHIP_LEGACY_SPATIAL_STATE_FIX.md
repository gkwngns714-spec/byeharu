# MAINSHIP LEGACY SPATIAL-STATE FIX — Recon, Audit & Design Decision

**Status:** DECIDED · slice 1 (DEPARTURE/HALT pair-writes) IMPLEMENTED in migration 0152
(`20260618000152_mainship_legacy_in_flight_spatial_state.sql`) · slice 2 (ARRIVAL settle + shared
docked-ship helper) IMPLEMENTED in migration 0153
(`20260618000153_mainship_legacy_arrival_docks_ship.sql`); the round-trip verifier is the remaining step
**Date:** 2026-07-06 · **Branch:** `autopilot/20260703-064048` · **Migration head:** `20260618000151_legacy_settle_arrival_on_demand.sql` (0151)

---

## 0. LOCKED SCOPE

**MAY touch (implementation steps that follow this doc):**
- New **forward-only** migration(s) under `supabase/migrations/` (numbered after 0151): the legacy-writer
  fixes, ONE shared ship-docking transition helper extracted from the OSN dock writer, and (only if ever
  shown necessary — see §4, currently NOT needed) a guarded idempotent data-repair.
- The verifier: a new/extended `verify-*.mjs` (natural home: extend `scripts/verify-mainship-move.mjs`
  or add `scripts/verify-mainship-spatial.mjs` on the dark-phase verifier pattern / shared harness of
  `verify-fitting.mjs`) proving docked → send → travel → arrive → docked with the 0055 CHECKs never violated.
- Law/design docs **in the same step as the code**: `docs/SYSTEM_BOUNDARIES.md` (only if a writer/ownership
  fact changes), a `docs/DEV_LOG.md` entry, `docs/MAINSHIP_TRANSITION.md` (the legacy spatial-state rule
  belongs there), and this doc.

**MUST NOT touch:**
- Any shipped migration (forward-only only — 0050…0151 stay byte-identical).
- The frontend (all RPC signatures unchanged; no client edit needed).
- Any feature flag/capability: `mainship_send_enabled` stays **as-is (live-ENABLED — never flipped by this
  work)**; `mainship_space_movement_enabled` stays **OFF/dark**. No silent activation of anything.
- The production database, CI/deploy/verifier workflows. No merge, no deploy — PR-ready on this branch only.

---

## 1. Starting point (confirmed)

- Current branch: `autopilot/20260703-064048` (verified via `git branch --show-current`).
- Migration head: `20260618000151_legacy_settle_arrival_on_demand.sql` (0151) — verified last file in
  `supabase/migrations/`.
- Flags: `mainship_send_enabled` gates every visible legacy main-ship command (0050:73, 0053:34, 0149:67,
  0151:145) and is **live-ENABLED — this work does not touch or flip it**. The coordinate-domain flag
  `mainship_space_movement_enabled` (0060/0150) is **OFF/dark** and stays OFF.
- **The 0055 lifecycle CHECKs are CORRECT and stay untouched.** This goal fixes the WRITERS, never the
  constraints. The six constraints (0055:143-161):

  | Constraint | Rule |
  |---|---|
  | `main_ship_instances_ss_in_space_status` | `spatial_state='in_space'` ⇒ `status='stationary'` |
  | `main_ship_instances_ss_at_location_status` | `spatial_state='at_location'` ⇒ `status='stationary'` |
  | `main_ship_instances_ss_in_transit_status` | `spatial_state='in_transit'` ⇒ `status='traveling'` |
  | `main_ship_instances_ss_home_status` | `spatial_state='home'` ⇒ `status='home'` |
  | `main_ship_instances_ss_destroyed_status` | `spatial_state='destroyed'` ⇒ `status='destroyed'` |
  | `main_ship_instances_stationary_spatial_state` | `status='stationary'` ⇒ `spatial_state IN ('in_space','at_location')` (IS TRUE — NULL rejected) |

---

## 2. Complete writer audit — every writer of `main_ship_instances` status/spatial_state

Method: `grep -i 'update ... main_ship_instances'` across all of `supabase/migrations/` (17 files matched),
plus the INSERT path (commission). Non-state writers excluded from risk analysis: `rename_main_ship`
(0043:117 — name only), cargo backfills (0076:30, 0077:132 — `cargo_capacity_m3` only).

| # | Writer (latest definition) | status write | spatial_state write | Can it run on a non-NULL-ss ship? | Verdict |
|---|---|---|---|---|---|
| 1 | `send_main_ship_expedition` (0050:146, re-emitted 0051:149) | `'traveling'` | **NO** | Requires `status='home'`. `spatial_state='home'` is never written by any shipped writer (0113:51 records this), so home ships are always ss=NULL today → no violation reachable **today**; latent trap if ss='home' ever appears. | **SAME-CLASS, latent** — fix for uniformity/defense |
| 2 | `request_main_ship_return` (0050:223, re-emitted 0051:213) | `'returning'` | **NO** | Requires only fleet `status='present'`. A commissioned/normalized ship is `at_location` **with fleet 'present'** (0072/0084) → sets `status='returning'` leaving `spatial_state='at_location'` → **violates `ss_at_location_status`**. | **LIVE BUG (second, same class)** |
| 3 | `process_mainship_expeditions` (0050:246) | `'home'` | **NO** | Only fires on status `traveling`/`returning` **with no in-flight tagged fleet**. An OSN `in_transit` ship (ss non-NULL, status='traveling') always has a `'moving'` fleet (0056:145) → excluded by the NOT EXISTS. No reachable violation; correctness rests on that fleet-existence guard. | Safe (guarded); note the coupling |
| 4 | `move_main_ship_to_location` (0053:105) | `'traveling'` | **NO** | Requires only fleet `status='present'` → runs on an `at_location` ship → sets `status='traveling'` leaving `spatial_state='at_location'` → **violates `ss_at_location_status`**. | **THE REPORTED LIVE FAILURE — confirmed** |
| 5 | `command_main_ship_stop_transit` (0149:152) | `'returning'` | **NO** | Requires a **legacy** `fleet_movements` row `status='moving'`; an OSN `in_transit` ship has none (0056:148 asserts `v_has_legacy=false`), and legacy transits are ss=NULL. Unreachable today. | **SAME-CLASS, latent** — fix for uniformity |
| 6 | `movement_settle_arrival` (0151:45) + `process_fleet_movements` (0151:100) | **none** (ship row untouched) | **NO** | Location branch settles fleet/presence only — the ship stays `status='traveling'`, ss=NULL forever while "present" (the legacy_present quirk). Base branch: `fleet_complete`, then #3 homes the ship. | No violation, but the **arrival never settles the ship** — the design gap this fix closes |
| 7 | `repair_main_ship` (0052:49, re-emitted 0081:96) | `'home'` | **NO** | Requires `status='destroyed'` (0081:88). Destroyed ships always have ss=NULL — 0059:99 explicitly clears it ("D-1"), and ss='destroyed' is never written. `'home'` with ss=NULL is legal (`legacy_home`). | Safe today; relies on the 0059 D-1 invariant |
| 8 | `dev_set_main_ship_destroyed` (0052:106 → re-created 0059:99) | `'destroyed'` | **YES** (ss=NULL, coords NULL) | Pair-write. | Correct |
| 9 | `mainship_space_begin_move` (0057:242) / `..._begin_move_core` (0067:378) | `'traveling'` | **YES** (`'in_transit'`, coords NULL) | Pair-write; OSN, dark-gated. | Correct |
| 10 | `process_mainship_space_arrivals` space-settle (0058:105 → 0061:233 → 0067:806) & `mainship_space_settle_space_arrival` (0064:84) | `'stationary'` | **YES** (`'in_space'` + coords) | Pair-write. | Correct |
| 11 | `mainship_space_dock_at_location` (0061:131 → 0067:618) — dock branch; park-in-space fallback (0061:106 → 0067:597) | `'stationary'` | **YES** (`'at_location'`, coords NULL / `'in_space'` + coords) | Pair-write. **This is the canonical ship-docking transition — the extraction source for the shared helper.** | Correct |
| 12 | `mainship_space_stop` / `command_main_ship_space_stop` (0064:319 → 0067) | `'stationary'` | **YES** (`'in_space'` + coords) | Pair-write; dark-gated. | Correct |
| 13 | `command_main_ship_settle_arrival` (0150) | — reuses #10/#11 (no direct ship write of its own; gated `mainship_space_movement_enabled`, 0150) | via helpers | Pair-writes via helpers. | Correct |
| 14 | `port_entry_commission_writer` (0072:23) / `commission_first_main_ship` (0072:98) — the writer INSERTs the ship row directly in canonical shape (0072:41-43); additional-ship commission (0080, flag `mainship_additional_commission_enabled`) | `'stationary'` (at INSERT) | **YES** (`'at_location'`, coords NULL, at INSERT) | Pair-written at birth; the writer asserts `validate_context='at_location'` before returning (0072:89). `commission_first_main_ship` is **ungated** (live) — this is exactly how live ships are `at_location` while the OSN movement flag stays dark. | Correct — and the source of the live `at_location` population |
| 15 | `normalize_main_ship_dock` (0072:158; ship UPDATE at 0072:227) and its `p_main_ship_id`-parameterised re-creation (0084:28, same name; ship UPDATE at 0084:99) | `'stationary'` | **YES** (`'at_location'`, coords NULL) | Pair-write; asserts `validate_context='at_location'` after (0072:235). | Correct |

**Failure mechanism of the confirmed live bug (#4):** commission (0072, ungated, live) creates the ship
`status='stationary', spatial_state='at_location'` with its fleet `'present'` at a starter port. The legacy
move surface (`mainship_send_enabled` live-ENABLED) accepts any `'present'` main-ship fleet.
`move_main_ship_to_location` then executes `update main_ship_instances set status='traveling'` (0053:105)
**without touching `spatial_state`** → `ss_at_location_status` fires → the whole RPC transaction aborts.
`request_main_ship_return` (#2) is the identical class on the same origin state (sets `'returning'`).
Every legacy status-writer (#1–#7) is spatial_state-blind; every OSN/commission writer (#8–#15) pair-writes.
**The constraints correctly rejected an illegal write; the writers are what must change.**

---

## 3. Empirical question: are legacy send/move targets always dockable ports?

**Finding: NO — active `activity_type='none'` locations that are NOT dockable exist in the shipped world
data, and they are legal legacy targets.**

How determined (static analysis of shipped seeds + the canonical legality rule):

- Legacy target admission (0050:101-106, 0053:68-73) requires only: location exists, `status='active'`,
  `activity_type='none'`. Nothing else.
- Dockability per `mainship_space_location_target_legal` (0067:60-112) additionally requires:
  `physical_role IN ('city','port')` + active zone/sector + **exactly one** active `'docking'`
  `location_services` row + **exactly one** active `'location'`-kind `space_anchors` row (finite, in-bounds).
- The base world seed (`20260616000002_world_map.sql:151`) creates two ACTIVE `activity_type='none'`
  locations — **'Safe Rally Point'** (Wreck Belt) and **'Quiet Drift'** (Ion Storm Route). 0065 added
  `physical_role` with default `'unclassified'` and explicitly did NOT reclassify existing rows (0065:23-24);
  `location_services` was created EMPTY (0065:31-34). No later migration grants these two a role, a docking
  service, or an anchor. They therefore fail `target_unsupported_role` / `target_no_docking_service` /
  `target_anchor_not_unique` — **active, 'none', legal legacy targets, non-dockable**.
- The only dockable-seeded locations are the three 0066 starter ports (Haven Reach / Slagworks Anchorage /
  Driftmarch Waypost: role city/port + active docking service + active anchor), seeded `'hidden'` and flipped
  active only by the human-gated `reveal_starter_ports()` (0068, service_role-only, not invoked by migration).

**Design consequence:** the arrival non-dock fallback branch is a REAL, reachable path (not defensive-only).

---

## 4. Existing live rows — is a data-repair needed?

**Conclusion: a data-repair is NOT needed; if one is included at all it is a guarded idempotent no-op kept
purely as defense.** Reasoning:

- The six 0055 CHECKs reject every CHECK-inconsistent pair **at write time**, and they were added in the same
  migration that introduced `spatial_state` (all rows NULL) and the `'stationary'` status (no pre-existing
  rows) — so no shipped row has ever been able to violate them.
- The live failures are plpgsql exceptions raised by the CHECK inside the RPC transaction: the entire
  transaction (presence_complete, movement row, fleet transition, ship write) **rolls back atomically**.
  The bug leaves the command failing loudly — it cannot leave a half-written row behind.
- The only *logical* (CHECK-legal) oddity that exists by design: legacy-arrived ships sit in
  `legacy_present` with `status='traveling'` (writer #6 never settles the ship; `mainship_space_validate_context`
  0056:161-163 classifies `legacy_present` without reading ship status). The writer fix ends this for future
  arrivals; existing such rows are fully functional the moment the writers are fixed (their ss is NULL), and
  `normalize_main_ship_dock` (0072) already exists as the explicit upgrade path — so no repair migration
  touches them.

---

## 5. DESIGN DECISION (recorded; self-approved under my design authority)

**Rule: the legacy movement family lives entirely in the `spatial_state = NULL` legacy domain.** It must NOT
claim the coordinate-domain states `in_transit`/`in_space`: those require coordinate-movement linkage that
`mainship_space_validate_context` (0056:133-149) enforces — `in_transit` demands an active
`main_ship_space_movements` row and NO legacy movement (0056:146-148), so a legacy ship carrying a
`fleet_movements` row marked `in_transit` would read as **contradictory**. The in-flight legacy
representation is therefore `spatial_state=NULL` (validate_context state `legacy_transit`, 0056:165-166).

**DEPARTURE** — `send_main_ship_expedition` (0050/0051) and `move_main_ship_to_location` (0053): the SAME
write that sets `status='traveling'` also sets `spatial_state=NULL, space_x=NULL, space_y=NULL`, cleanly
dropping a canonically-docked (`at_location`/`stationary`) ship into legacy mode. This is the direct fix for
both live bugs and is idempotent for already-NULL ships.

**HALT / RETURN** — `command_main_ship_stop_transit` (0149) and `request_main_ship_return` (0050/0051):
same — the status write (`'returning'`) carries `spatial_state=NULL, space_x=NULL, space_y=NULL` in the same
statement.

**ARRIVAL at a named location** — `movement_settle_arrival` location branch (0151): settle the SHIP, not
just the fleet:
- **Dockable target** (passes `mainship_space_location_target_legal`): settle to the canonical docked pair
  `status='stationary', spatial_state='at_location', space_x=NULL, space_y=NULL` — **REUSING one shared
  ship-docking transition helper extracted from the OSN dock writer** (`mainship_space_dock_at_location`,
  0061:131/0067:618), called by both the OSN dock path and the legacy arrival path. Never a duplicated copy
  (HARD RULE: one helper, every call site, same step). The resulting shape satisfies canonical
  `at_location` (fleet `'present'`/`location`-mode + matching active presence come from the existing
  `fleet_set_present` + `presence_create` calls already in the branch).
- **Non-dockable target** (REACHABLE — §3: e.g. Safe Rally Point / Quiet Drift): settle to the legacy
  representation `spatial_state=NULL` with a legal legacy status. `'stationary'` is NOT legal here
  (`stationary_spatial_state` forbids it with ss=NULL); the decision is to keep the existing
  `legacy_present` convention (ship status stays `'traveling'` while fleet-present — the shape
  validate_context already classifies), making the non-dock branch an explicit, documented settle rather
  than an accident.

**ARRIVE-HOME + RECONCILER** — `movement_settle_arrival` base branch + `process_mainship_expeditions`
homing to `status='home'` stays legal untouched, because under this rule the ship is `spatial_state=NULL`
throughout the entire legacy leg (`'home'` with ss=NULL = `legacy_home`, 0056:158-159).

**Rationale:** the legacy domain keeps exactly one representation (ss=NULL) end-to-end, so every legacy
status write is constraint-legal by construction; the coordinate domain keeps sole ownership of non-NULL
spatial_state; the ONLY crossing point is the genuine dock at a real port, which goes through the ONE shared
canonical docking transition. No constraint changes, no new movement authority, no flag changes, acyclic
call graph preserved (legacy arrival calls a Main-Ship-owned leaf helper downward).

---

## 6. Implementation plan & status

1. **DONE — migration 0152** (`20260618000152_mainship_legacy_in_flight_spatial_state.sql`): the
   DEPARTURE/HALT half. New Main-Ship-owned leaf `mainship_mark_legacy_in_flight(ship, status)`
   (service_role-only; `status ∈ ('traveling','returning')` guarded; one statement writes
   `status + spatial_state=NULL + space_x/y=NULL`), and the four legacy writers (#1, #2, #4, #5 of the §2
   audit) re-created body-verbatim from 0051/0053/0149 with only the bare status UPDATE swapped for the
   helper call (diff-proven, one hunk per function). CREATE OR REPLACE preserved the four RPCs' client
   grants; only the new helper was grant-locked. Doc-sync shipped in the same step
   (`docs/SYSTEM_BOUNDARIES.md` "Legacy in-flight spatial representation" blockquote + `docs/DEV_LOG.md`
   2026-07-06 entry). No data-repair (§4).
2. **DONE — migration 0153** (`20260618000153_mainship_legacy_arrival_docks_ship.sql`): the ARRIVAL half.
   New Main-Ship-owned leaf `mainship_mark_docked_at_location(ship)` (service_role-only; the ONE canonical
   docked-pair write), extracted from the OSN Dock-0 writer's dock branch: `mainship_space_dock_at_location`
   re-created from its LATEST shipped body (0067:499 — supersedes the 0061 birth body cited in §5) with only
   that inline ship write swapped for the helper (terminal-failure `in_space` write untouched;
   diff-proven), and `movement_settle_arrival` re-created from 0151 body-verbatim with the location branch
   gaining the §5 dock/non-dock ship settle: `fleets.main_ship_id` non-NULL +
   `mainship_space_location_target_legal` pass → helper; otherwise no ship write (non-dockable 'none'
   targets stay coherent `legacy_present` — the reachable §3 case; unit fleets untouched). Accepted
   documented micro-delta: the dock branch's ship `updated_at` stamps `now()` via the shared helper instead
   of `v_settled_at` (bookkeeping-only; movement `resolved_at` + fleets stamps keep `v_settled_at`).
   Doc-sync shipped same-step (SYSTEM_BOUNDARIES "Canonical docked-ship write (0153)" blockquote;
   DEV_LOG 2026-07-06 slice-2 entry).
3. **NEXT — the verifier** proving docked → send → travel → arrive → docked with the 0055 CHECKs never
   violated (dark-phase verifier pattern), plus same-step doc sync (`docs/MAINSHIP_TRANSITION.md` gets the
   legacy ss=NULL rule when the family is complete; `docs/DEV_LOG.md` entry; `docs/SYSTEM_BOUNDARIES.md`
   again only if a writer/ownership fact changes).

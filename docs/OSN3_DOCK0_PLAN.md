# OSN-DOCK-0 — Explicit Named-Location Arrival for OSN (PLAN ONLY)

> **Status: PLANNING ONLY — local-only, code-free.** No code, migration, commit, push, deploy, flag change,
> or deletion. This plan defines the smallest missing replacement capability identified by PRES-0:
> when a main ship completes an OSN coordinate movement that **explicitly targets a named location**, the OSN
> arrival processor performs location-arrival/docking instead of ending only as generic `in_space`.
>
> **Resolved decisions carried in:** **D1** generic unit fleets are *frozen & isolated* (not a blocker, not
> deleted, not depended upon) — main-ship OSN must not create/require/depend on generic `fleets`/
> `fleet_movements` behavior. **D2** explicit location-target contract (`target_kind='location'` +
> `target_location_id`, server-validated, **no coordinate-proximity inference**). **D-data** cutover/reset is
> deferred to the later plan — **nothing is reset/cancelled/migrated here.**

## Hard boundaries (restated)
No canonical galaxy redesign · no location-coordinate migration · no renderer migration · no S6C/S6D · no
player tap/CTA · no flag enablement (`mainship_space_movement_enabled` stays **FALSE**) · no legacy deletion ·
no generic unit-fleet refactor · **no legacy `process_fleet_movements` reuse as a hidden dependency** · no
production behavior change.

## Two grounding facts (verified)
- **The schema already enforces D2.** `main_ship_space_movements.target_kind in ('space','location','base')`
  with a CHECK binding `target_location_id` exactly to `target_kind='location'` (`0055:31-35, 65-70`). The
  explicit contract is structural, not advisory.
- **The destination state already exists in the validator.** `mainship_space_validate_context` defines a
  coherent **`at_location`** state (`0056:137-142`) — spatial_state `at_location`, status `stationary`, a single
  `present`/`location_mode='location'` fleet with matching active `location_presence`. **Nothing currently
  transitions a ship *into* `at_location` via OSN** — S4 only ever settles to `in_space` (`0058:105-108`).
  OSN-DOCK-0 is precisely the missing transition that produces the already-defined `at_location` state.
- **Double-dark today.** The live writer (`mainship_space_begin_move` / S6A `command_main_ship_space_move`)
  only ever creates **`target_kind='space'`** moves (the wrapper takes raw `x,y`). So even with the flag ON, no
  location-targeted movement exists until a *later* targeting slice. DOCK-0 is therefore provable only via
  **synthetic fixtures** and ships **zero** production behavior regardless of flag state.

---

## 1. Exact legacy docking effects (`process_fleet_movements`, location branch `0009:29-40`)
On a due `target_type='location'` movement the legacy processor performs, in order:
1. **Location read** — `select l.activity_type, l.zone_id, z.sector_id from locations l join zones z` for
   `target_location_id` (`0009:31-34`).
2. **Movement bookkeeping** — `update fleet_movements set status='arrived', resolved_at=now()` (`0009:36`).
3. **Fleet → present** — `fleet_set_present(fleet, sector, zone, location)` → fleet `status='present'`,
   `location_mode='location'`, `current_sector/zone/location` set (`0009:38`).
4. **Presence + activity** — `presence_create(player, fleet, sector, zone, location, activity)` → inserts
   `location_presence` (`status='active'`) and calls `activity_start(presence, activity)` (`0008:73-91`).

### Separation
| Effect | Class | DOCK-0 treatment |
|---|---|---|
| Location read (`activity_type`/`zone`/`sector` for `target_location_id`) | **reusable location-domain** | reuse — same lookup, keyed on `v_mv.target_location_id` |
| `presence_create(...)` → `location_presence` + `activity_start(...)` (`0008:73-91`) | **reusable location-domain** (Presence-owned; not tied to `fleet_movements`) | **reuse directly** — do not reimplement presence/activity |
| Fleet → `present`/`location_mode='location'`/`current_*` (`fleet_set_present`) | **reusable location-domain fleet shape** (matches the validator's `at_location` fleet) | reuse the *shape*; see §3 for call-helper vs focused-update |
| `update fleet_movements set status='arrived'` (`0009:36`) | **generic fleet-movement-only** | **DO NOT touch** — OSN's analogue (`update main_ship_space_movements … 'arrived'`) is already done by S4 (`0058:94-96`) |
| Base/return branch: `base_merge_units` + `fleet_complete` (`0009:42-54`) | **generic fleet-only** | **out of scope** — DOCK-0 is *location* arrival only; OSN base/home arrival is a separate concern |
| Main-ship **legacy-only** effects | (none in the arrival branch) | the legacy main-ship route reuses generic `process_fleet_movements` unchanged; its main-ship-only logic lives in the send/move/return RPCs + `process_mainship_expeditions`, **not** in docking |

**Consequence:** OSN docking reuses the *location-domain* effects (presence/activity + the present-fleet shape)
and **must not** reuse, lock, or write `fleet_movements` — preserving S2/S4's invariant that the coordinate
domain never touches the legacy movement table (`0056:10-13`).

---

## 2. OSN docking arrival state machine
DOCK-0 adds a **terminal branch** to `process_mainship_space_arrivals`, selected by `v_mv.target_kind`. The
existing S2 lock→validate→exclusion frame (`0058:49-91`) is unchanged; only the settlement (step 7) branches.

| # | Case | Detection | Outcome |
|---|---|---|---|
| a | **Valid explicit location target** | `v_mv.target_kind='location'` AND `target_location_id` resolves to a usable location | **Dock:** movement→`arrived`/`auto_arrival`; fleet→`present`/`location_mode='location'`/`current_*` set/`active_space_movement_id=NULL`/`active_movement_id=NULL`; ship→`stationary`/`spatial_state='at_location'`; `presence_create(...)` → active presence + `activity_start`. Result = the validator's coherent `at_location` state. |
| b | **Free-space target** | `v_mv.target_kind='space'` | **Unchanged** existing settlement → `in_space` (`0058:98-108`). No presence. (A `space` move that *shares coordinates* with a location stays free-space — no proximity inference.) |
| c | **Base target** | `v_mv.target_kind='base'` | **Out of DOCK-0 scope** — no `base` move can be created by the current writer; if one somehow exists, frozen-failure (leave untouched, log). Defer to a later home-arrival slice. |
| d | **Missing/deleted target location** | `target_kind='location'` but `target_location_id` no longer resolves | **Frozen failure** (S4 policy, `0058:13-16`): leave all rows UNTOUCHED, emit a notice, retry/skip next tick. *No* fallback to `in_space` (would silently lose the player's destination). |
| e | **Disabled/inactive location** | location resolves but is not a valid arrival target (pending **Q3** — does `locations` have an active/enabled flag?) | If such a concept exists: frozen failure + notice. If not: treat any resolvable location as valid. |
| f | **Coordinate mismatch** (`target_x/y` ≠ location's coords) | n/a by contract | **Ignored** — docking keys on `kind`+`id` only (**D2**). `target_x/y` are provenance, never a docking condition. |
| g | **Activity not yet implemented** | resolved location `activity_type` ∉ {`none`} (e.g. `hunt_pirates`) | `activity_start` raises (`0008:61-66`). DOCK-0 dock proof uses **`none`/safe-zone** locations; non-`none` docking naturally defers to when that activity (Combat/M4+) is wired. Treated under frozen-failure (the whole settlement txn rolls back, row left `moving`, retried) — **flag as Q4**: accept as deferred, or pre-gate docking to implemented activities. |
| h | **Duplicate / concurrent arrival** | two workers pick the same due row | Prevented by the existing frame: ship claimed `for update skip locked` (`0056:37-48`), re-read-under-lock confirms still the active `moving` row + linkage (`0058:73-91`), and `one_active_presence_per_fleet` unique index (`0008:39-41`) backstops a double presence. Exactly-once preserved. |
| i | **Destroyed / invalid ship** | `validate_context` ≠ coherent `in_transit` (`0058:57-62`) | Existing frozen-failure skip — unchanged; docking never runs on an incoherent context. |
| j | **Retry / idempotency** | settled row is `status='arrived'` | No longer matched by the `status='moving'` due-scan (`0058:42-47`) nor the partial unique indexes; re-runs are no-ops. Immutable S3 creation receipt untouched. |

### Cross-domain exclusion coherence (critical)
The pre-settlement exclusion guard runs while the ship is still `in_transit` with **no** presence, so it passes
(`0056:260-264` only flags presence when spatial_state ∈ `in_space`/`in_transit`). After docking the ship is
`at_location` (∉ that set), so the new active presence is **coherent**, not a conflict. The presence is created
*inside* the settlement txn, after all guards — no ordering inversion. The fleet CHECK
`active_space_movement_id NOT NULL ⇒ moving/movement` (`0055:105-109`) is satisfied because docking **clears**
`active_space_movement_id` while setting `present`/`location`.

---

## 3. Minimum safe implementation boundary
- **Migrations/functions likely to change (one new forward migration, `0061`):**
  - `process_mainship_space_arrivals` — replace the unconditional `in_space` settlement with the
    `target_kind` branch (a = dock, b = existing in_space, c/d/e = frozen-failure). This is the **only** behavior
    change. Re-lock block carried verbatim (the function stays service_role-only).
  - **No** change to S2 helpers, `mainship_space_begin_move`, the wrapper, the schema, or any flag.
- **Extract a shared helper, do not copy.** Introduce a small **location-domain** server helper, e.g.
  `location_dock_fleet(player, fleet, location_id) → presence_id`, that performs the *reusable* effects only:
  the location/zone/sector read + the present-fleet shape + `presence_create`. Both the legacy
  `process_fleet_movements` location branch **and** the new OSN dock branch can call it — eliminating a copy and
  guaranteeing identical presence/activity semantics. *(Refactoring the legacy caller to use it is optional and
  can be deferred; DOCK-0 may land the helper + the OSN caller only, leaving legacy untouched to minimize blast
  radius — decide as **Q1**.)* The helper must take a `fleet_id` + `location_id` and must **not** read or write
  `fleet_movements`.
- **No dependency on legacy fleet-movement rows.** OSN docking reads only: the `main_ship_space_movements` row
  (already locked), `locations`/`zones`, and writes `location_presence` + `fleets` + `main_ship_instances`. It
  never selects, locks, or updates `fleet_movements`. The S2 canonical lock order (ship → fleets →
  main_ship_space_movements → location_presence, `0056:10-13`) already covers every row docking touches, with
  `location_presence` locked last — no new lock target, no inversion risk against frozen
  `process_fleet_movements`.
- **Preserve S4 exactly-once.** Keep the existing claim-ship-skip-locked + re-read-under-lock + linkage-match
  frame entirely; add settlement logic *inside* the same already-locked txn. The `status='moving'→'arrived'`
  flip + partial unique indexes + `one_active_presence_per_fleet` remain the exactly-once guarantee.
- **Ship spatial_state target.** Set `spatial_state='at_location'`, `status='stationary'` (matches validator
  `0056:137-142`). Confirm `'at_location'` is in the `main_ship_instances.spatial_state` CHECK domain (**Q2** —
  verify against the OSN-2 spatial-state migration; `validate_context` references it, so expected present).
  `space_x/space_y` for a docked ship are unconstrained by the `at_location` validator and unused by the
  resolver's at_location render path — recommend setting them to `target_x/target_y` for provenance (**Q5**,
  minor).

### Open implementation questions
- **Q1** — land `location_dock_fleet` + OSN caller only (legacy untouched), or also refactor legacy to call it now?
- **Q2** — confirm `spatial_state` CHECK includes `'at_location'`.
- **Q3** — does `locations` carry an active/enabled/soft-delete flag that should gate docking (case e)?
- **Q4** — non-`none` activity docking: accept as deferred-via-frozen-failure, or pre-gate docking to
  implemented activities so a `hunt_pirates` arrival has explicit handling rather than a rolled-back retry loop?
- **Q5** — set docked `space_x/space_y` to `target_x/y` or leave/null.

---

## 4. Synthetic dark proof plan
Pattern: the project's disposable-Postgres real-chain harness (migrations `0001..0061`), service_role, **no
production data, flag stays FALSE**, fixtures insert rows directly (bypassing the not-yet-built location
targeting writer).

- **Fixtures** — a synthetic player/base/ship/fleet in a coherent `in_transit` shape, plus a
  `main_ship_space_movements` row with `target_kind='location'`, `target_location_id=<safe-zone loc>`,
  `arrive_at<=now()`, linked `active_space_movement_id`. A parallel `target_kind='space'` fixture for the
  unchanged path.
- **Positive (case a)** — run `process_mainship_space_arrivals`; assert exactly-once docking: movement
  `arrived`/`auto_arrival`; fleet `present`/`location_mode='location'`/`current_location_id`=target/
  pointers cleared; ship `stationary`/`at_location`; **one** active `location_presence` for the fleet with the
  location's `activity_type`; `validate_context` now returns coherent `at_location`.
- **Exactly-once** — run the processor twice (and a simulated concurrent double-claim); assert no second
  presence, no re-settlement, no error (idempotent no-op on the second pass).
- **Negative** — `target_kind='space'` still settles to `in_space` with **no** presence (case b); missing
  `target_location_id` target → frozen-failure, row untouched (case d); incoherent/destroyed context → skip
  (case i); (if Q4=pre-gate) non-`none` activity → explicit deferred handling rather than a silent loop.
- **Legacy regression protection** — assert `process_fleet_movements` location/base arrivals are byte-for-byte
  unchanged (especially if Q1 refactors it to share `location_dock_fleet`): same fleet/presence/activity
  outcome on a legacy `fleet_movements` fixture. Assert OSN docking touched **no** `fleet_movements` row.
- **Boundary/anti-cheat** — re-confirm the re-lock block: dock helper + processor are service_role-only; the
  canonical client RPC inventory is unchanged from `0060`.
- **Flag invariance** — assert `mainship_space_movement_enabled` is still FALSE and that the processor settles
  already-created movements regardless (the established S4 rule, `0058:6-8`).

---

## 5. What OSN-DOCK-0 explicitly does NOT solve
- **No final map unification** — `buildNormalizer`/`legacy_dynamic`/the renderer are untouched (PRES-2…5).
- **No hand-designed canonical galaxy** and **no location-coordinate migration** (PRES-1 / D-data).
- **No player coordinate command UI** — no S6C tap/select/confirm/recall; the S6A wrapper stays headless.
- **No location *targeting writer*** — `mainship_space_begin_move`/`command_main_ship_space_move` still produce
  only `target_kind='space'` moves; *creating* location-targeted movements is a separate later slice.
- **No movement enablement** — `mainship_space_movement_enabled` stays FALSE; no flag flip, no S6D.
- **No legacy retirement** — the four legacy main-ship RPCs, reconciler, UI, API, flag, and tests all remain.
- **No generic unit-fleet change** — fleets/`fleet_movements`/`process_fleet_movements` are frozen & isolated
  (D1), neither extended nor deleted nor depended upon by the OSN dock path.
- **No base/home OSN arrival** and **no combat/`hunt_pirates` activity** — DOCK-0 proves safe-zone (`none`)
  location docking only.
- **No state reset/cancel/migration** — D-data is deferred to the cutover plan.

---

*Plan only — no code, migration, commit, push, deploy, flag change, or deletion performed. Awaiting resolution
of Q1–Q5 and an explicit "begin OSN-DOCK-0" before any implementation. This document is local-only and is not
a DEV_LOG/project-guide closure entry (those are reserved for deployed, verified milestones).*

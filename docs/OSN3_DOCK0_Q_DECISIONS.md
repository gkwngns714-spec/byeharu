# OSN-DOCK-0 — Q1–Q5 Semantic Decision Packet (DECISION ONLY)

> **Status: DECISION PACKET — local-only, code-free.** No code, migration, test, commit, push, deploy, flag
> change, or deletion. Implementation is **not** authorized. This resolves the five open semantic questions
> from `OSN3_DOCK0_PLAN.md` so coding can be authorized in a later, explicit step.
>
> **Confirmed directions carried in:** D1 (unit fleets frozen/isolated, not an OSN dependency) · D2 (explicit
> `target_kind='location'` + exact `target_location_id`, server-validated, never proximity-inferred) · D-data
> (no reset/cancel/migrate/delete now) · DOCK-0 dark + synthetic-only while
> `mainship_space_movement_enabled=FALSE` · OSN arrival never reads/creates/relies-on `fleet_movements`.
>
> **Additional boundary (new):** do **not** refactor or alter legacy `process_fleet_movements` to share
> implementation. Legacy arrival stays untouched; OSN gains a **narrow private docking primitive**; a shared
> helper is acceptable only if it neither changes legacy behavior nor widens DOCK-0's proof surface. Future
> consolidation is a separate chartered cleanup after OSN docking is proven + legacy retirement is chartered.

---

## Q1 — Code shape of the docking effects (private primitive vs shared helper)
| Item | Content |
|---|---|
| **Question** | How is OSN docking implemented relative to the legacy location-arrival effects — a shared helper, an OSN-private primitive, or inline in the processor? |
| **Evidence** | Legacy location-arrival effects: `process_fleet_movements` location branch (`0009:29-40`) → location read + `fleet_set_present` + `presence_create`. `presence_create` (`0008:73-91`) is Presence-owned and operates on `(player,fleet,sector,zone,location,activity)` — not tied to `fleet_movements`. New boundary forbids touching legacy to share code. |
| **Options** | **(A)** OSN-private narrow primitive (e.g. `mainship_space_dock_at_location`), legacy untouched. **(B)** extract a shared helper both legacy + OSN call now. **(C)** inline the dock logic directly inside `process_mainship_space_arrivals`. |
| **Recommendation** | **(A)** OSN-private narrow primitive; legacy untouched; no shared helper now. |
| **Why** | (B) violates the new boundary (modifies legacy → regression risk + widened proof surface). (C) couples dock logic into the processor, harder to unit-test and to reuse for a future location-targeted **return**, and harder to delete cleanly. (A) isolates the one new behavior, keeps the proof surface to "the primitive + the processor branch," and leaves a clean seam for the *later* chartered consolidation. **Deletion impact:** a self-contained primitive is trivially removable/relocatable when legacy retires; no legacy edit to unwind. |
| **State effect** | Structural only — the primitive is the single mutation site that produces the Q2 `at_location` coherent state. |
| **Failure behavior** | One atomic mutation site invoked inside the processor's existing lock frame (`0058:49-91`); retry/replay safety is inherited from that frame (Q4/idempotency), not re-implemented. |
| **Test impact** | Prove the primitive via the processor on a synthetic location-targeted movement; **regression:** assert `process_fleet_movements` outcome is byte-unchanged and that the OSN path touches **no** `fleet_movements` row. |
| **Scope impact** | None — stays within the single new migration; **narrower** than the plan's earlier "shared helper" idea (which is now explicitly rejected). |

## Q2 — Exact docked main-ship state (and the coordinate question)
| Item | Content |
|---|---|
| **Question** | What exact `main_ship_instances` state does docking set, and what are `space_x/space_y`? |
| **Evidence** | Validator's coherent `at_location` (`0056:137-142`): ship `stationary`, fleet `present`/`location_mode='location'`/matching active presence. Domain CHECK allows `'at_location'` (`0054:43`). Coord CHECK (`0054:62-74`): **coords are non-null IFF `spatial_state='in_space'`** → any non-`in_space` state **requires NULL coords**. |
| **Options** | **(A)** `spatial_state='at_location'`, `status='stationary'`, `space_x/space_y=NULL`. **(B)** `in_space` + coords (this is *not* docking — wrong state). **(C)** invent a new spatial_state. |
| **Recommendation** | **(A)** — and `space_x/space_y=NULL` is **forced by the CHECK**, not a preference; setting target coords would **violate** `main_ship_instances_space_coords`. |
| **Why** | Matches the already-modeled `at_location` coherent state with **zero** schema change; the renderer's at_location path reads the **location's** coords (resolver §D), never `space_x/y`, so NULL loses nothing. Clean-cut: reuses the existing state axis rather than adding one. |
| **State effect** | ship → `stationary` / `spatial_state='at_location'` / `space_x=NULL` / `space_y=NULL`; fleet → `present` / `location_mode='location'` / `current_location/zone/sector` set / `current_base_id=NULL` / `active_space_movement_id=NULL` / `active_movement_id=NULL`; presence → one `active` row at the location. |
| **Failure behavior** | Coherent terminal; the `status='moving'→'arrived'` flip + cleared `active_space_movement_id` remove the row from both the due-scan and the partial unique index, so replay is a no-op. |
| **Test impact** | Assert the exact ship row (`stationary`, `at_location`, NULL coords); assert `validate_context` returns coherent `at_location`; assert `main_ship_instances_space_coords` + `fleets_active_space_movement_requires_moving` hold. |
| **Scope impact** | None. **Also resolves Q5** (coords forced NULL). |

## Q3 — Dockability gate (which location states may be docked)
| Item | Content |
|---|---|
| **Question** | Which `locations.status` (and/or `is_public`) values are valid OSN dock targets at arrival? |
| **Evidence** | `locations.status in ('active','locked','hidden')` (`0002:68-69`); `is_public boolean` (`0002:67`). FK `target_location_id → locations(id)` is **NO ACTION** (`0055:34`) → a referenced location **cannot be hard-deleted** (so "missing location" is FK-prevented; "disabled" via status UPDATE is the real case). |
| **Options** | **(A)** require `status='active'`. **(B)** dock regardless of status. **(C)** require `status='active'` AND `is_public=true`. |
| **Recommendation** | **(A)** gate arrival docking on `status='active'`; treat `'locked'`/`'hidden'` as **non-dockable** → Q4 deterministic terminal. Leave `is_public` to the **targeting writer** (it governs whether a location is *selectable* as a destination — a creation/pre-block concern, not arrival). |
| **Why** | `locked`/`hidden` = administratively disabled; docking into one would expose a disabled location's rules. `status='active'` is the minimal correct arrival gate. Gating arrival on `is_public` would conflate visibility with reachability and belongs upstream at target selection. |
| **State effect** | `active` → proceed to dock (Q2 state). Non-`active` → Q4 terminal failure. |
| **Failure behavior** | Deterministic: a location flipped to `locked`/`hidden` mid-transit yields, on arrival, a non-dockable → **terminal failure** (no loop). "Missing" cannot occur (FK NO ACTION). |
| **Test impact** | Active location → docks; a `'locked'` location fixture → terminal failure (no presence, no loop); document that the FK blocks location deletion while referenced. |
| **Scope impact** | None. |

## Q4 — Activity-start gating (REQUIRED explicit decision)
| Item | Content |
|---|---|
| **Question** | What happens when a dock target is valid + active but its `activity_type` is **not implemented** (e.g. `'hunt_pirates'`, M4-gated), so `activity_start` would raise? |
| **Evidence** | `activity_start` (`0008:52-68`): `'none'` → no-op; `'hunt_pirates'` → **raises** "not implemented until M4"; unknown → raises. `presence_create` calls `activity_start` **synchronously** in the same txn (`0008:88`). `location_presence.status` domain has **no** "pending"/"activity-deferred" value (`0008:20-21`). `one_active_presence_per_fleet` unique (`0008:39-41`). |
| **Options** | **(1)** dock and durably defer activity. **(2)** pre-block unsupported location targets *before movement starts* (at the targeting writer). **(3)** fail / roll back docking at arrival. |
| **Recommendation** | **(2) Pre-block — assigned to the FUTURE location-targeting writer; DOCK-0 restricts its dockable set to `activity_type='none'` (and `status='active'`) and proves only those.** Plus, inside DOCK-0's arrival processor, a **deterministic terminal guard** (a *bounded* form of 3, **not** a retry-rollback): a non-dockable location target that nonetheless arrives → movement `status='failed'` + explicit `terminal_reason='undockable_target'`; ship → `in_space` at `target_x/target_y`; fleet → completed/in-space shape; **no presence**; emit a notice. |
| **Why** | **(1) rejected:** no durable "docked-but-activity-pending" state exists; inventing one widens scope and risks a **half-docked** state (presence active but rules not running) — forbidden. **Pure (3) rollback/frozen rejected:** leaving the row `moving` makes the 30 s cron **loop forever** on the same failed `activity_start` — forbidden. **(2)** prevents the case at its source (target selection), keeps DOCK-0 narrow, and never half-docks. The arrival **terminal guard** is *defensive only* — once pre-block exists it is unreachable in the real flow — and it is **explicit** (terminal `failed` + `terminal_reason` + log), so it is **not** the *silent* `in_space` conversion the rule forbids; its sole job is to guarantee **no infinite cron loop** if a non-dockable target ever reaches arrival (synthetic fixture / future bug). A `failed` movement is terminal (sets `resolved_at`, leaves the `status='moving'` index) so it is never re-scanned. The ship **must** leave `in_transit` to stay coherent (a `failed` movement with the ship still `in_transit` is a stranded/contradictory state), and `in_space` at the arrival coordinate is the only truthful non-docked terminal. |
| **State effect** | Dockable (`none` + `active`) → full dock (Q2 state). Non-dockable (unsupported activity **or** non-`active`, Q3) → ship `stationary`/`in_space`/(`target_x`,`target_y`); fleet completed/in-space shape; movement `failed`/`undockable_target`; **no** `location_presence`. |
| **Failure behavior** | Dockable → exactly-once dock (lock frame + indices). Non-dockable → exactly-once **terminal failure**; terminal status removes it from the due-scan → **no replay loop**, **no half-dock**, **no silent success-as-in_space** (the failure is explicit + logged). |
| **Test impact** | Positive: `none`/active location → docks (Q2 asserts). Negative: a `hunt_pirates`-activity active location fixture → assert **not docked**, movement `failed`/`undockable_target`, ship `in_space`, **zero** presence rows, and a **second cron run is a no-op** (proves no loop). Negative: `locked` location (Q3) → same terminal path. Assert DOCK-0 builds **no** creation/pre-block path (pre-block is documented as the future writer's responsibility). |
| **Scope impact** | Tightens DOCK-0's *supported* dock set to `none`-activity + `active` locations; **adds the defensive terminal branch** to the processor (still one migration). The **pre-block itself is out of DOCK-0** (it lives in the future targeting writer); DOCK-0 only records it as that writer's hard precondition. |

## Q5 — Docked-ship coordinate provenance
| Item | Content |
|---|---|
| **Question** | On dock, set `space_x/space_y` to the target coordinate or NULL? |
| **Evidence** | Coord CHECK `0054:66-67`: non-null coords are legal **only** when `spatial_state='in_space'`. Docked state is `at_location` (Q2). The arrival coordinate is immutably recorded on the movement row `main_ship_space_movements.target_x/target_y` (`0055:32-33`). |
| **Options** | **(A)** NULL. **(B)** target coords (would set non-null coords in `at_location`). |
| **Recommendation** | **(A)** NULL — **forced** by the CHECK; (B) is **illegal** (violates `main_ship_instances_space_coords`). |
| **Why** | `at_location` is not `in_space`; provenance is not lost because the target coordinate stays on the (now `arrived`) movement row, and the renderer reads the **location's** coords for an at_location ship (resolver §D). |
| **State effect** | `space_x=NULL`, `space_y=NULL` on dock. |
| **Failure behavior** | n/a (no independent failure mode). |
| **Test impact** | Assert NULL coords and that `main_ship_instances_space_coords` is satisfied. |
| **Scope impact** | None (decided jointly with Q2). |

---

## 1. Recommended resolved Q1–Q5 answers
- **Q1 = (A)** — an **OSN-private narrow docking primitive**; legacy `process_fleet_movements` **untouched**; no shared helper now.
- **Q2 = (A)** — dock state is ship `stationary`/`spatial_state='at_location'`/**NULL coords**, fleet `present`/`location`/pointers cleared, one `active` presence (the validator's existing `at_location`).
- **Q3 = (A)** — dockability gate is `locations.status='active'`; `is_public` deferred to the targeting writer; "missing location" is FK-prevented.
- **Q4 = (2) pre-block** (owned by the future targeting writer) **+** DOCK-0 scoped to `activity_type='none'` **+** a defensive **deterministic terminal-failure** guard at arrival (movement `failed`/`undockable_target`, ship `in_space`, no presence, logged) — never half-dock, never loop, never *silent* `in_space`.
- **Q5 = (A)** — docked `space_x/space_y = NULL` (schema-forced).

## 2. Revised exact OSN-DOCK-0 implementation boundary (supersedes §3 of the plan)
- **One** new forward migration (`0061`) changing **only** `process_mainship_space_arrivals`, **plus** one new
  **OSN-private** `SECURITY DEFINER`, service_role-only docking primitive (e.g.
  `mainship_space_dock_at_location`). The migration's relock block carries the canonical client-RPC inventory
  verbatim from `0060` (no new client grant).
- **Supported dock set:** `v_mv.target_kind='location'` **AND** the referenced location is `status='active'`
  **AND** `activity_type='none'`. Docking sets the Q2 `at_location` state and calls `presence_create` (which
  runs the `'none'` no-op `activity_start`).
- **Non-dockable arrival** (unsupported activity or non-`active` location): the defensive **terminal** —
  movement `failed`/`terminal_reason='undockable_target'`, ship `in_space` at `target_x/target_y`, fleet
  completed/in-space shape, **no presence**, notice logged. Deterministic, single-shot, no loop.
- **Free-space arrival** (`target_kind='space'`): **unchanged** existing settlement → `in_space`.
- **Untouched:** legacy `process_fleet_movements` (no refactor/share); S2 helpers; `mainship_space_begin_move`;
  the S6A wrapper; the schema; **all** flags. No `fleet_movements` read/lock/write. No `target_kind='base'`
  handling (out of scope). The **pre-block** of unsupported targets is **not** built here (future targeting
  writer); DOCK-0 records it as that writer's hard precondition.
- **Exactly-once** is inherited from the existing S4 lock frame (`0058:49-91`) + the `status='moving'` partial
  indices + `one_active_presence_per_fleet`; DOCK-0 adds settlement *inside* that frame, never a new lock target.
- **Dark + synthetic-only:** `mainship_space_movement_enabled` stays **FALSE**; proof uses disposable-Postgres
  real-chain fixtures only; no production data; net production behavior change = **none**.

## 3. Single explicit approval phrase required before any coding
> **“begin OSN-DOCK-0”**

Until that exact phrase is given, no code, migration, test, primitive, commit, push, deploy, flag change, or
deletion will be produced.

---

*Decision packet only — no implementation performed. Both planning/audit documents
(`OSN3_S6B_PRES0_AUDIT.md`, `OSN3_DOCK0_PLAN.md`) and this packet remain local-only and uncommitted; no
DEV_LOG / project-guide closure entry is written (those are reserved for deployed, verified milestones).*

---

# Failure-State Preflight (read-only schema verification)

> Proves the Q4 undockable/invalid-arrival terminal is structurally valid against the **current** schema +
> arrival due-scan, before any implementation. Verification only — no code written.

### 1. Exact legal terminal movement status
**`status = 'failed'`** (with `resolved_at = now()`). The movement status domain is
`('moving','arrived','stopped','cancelled','failed')` (`0055:37-38`) — `failed` is legal. It is **unused by
any OSN writer**: S4 success uses `arrived`/`auto_arrival` (`0058:95`), S5 destruction uses
`cancelled`/`ship_destroyed` (`0059:72`). So `failed` carries **no existing OSN meaning to collide with** →
an unambiguous, non-silent "declared `target_kind='location'` outcome not achieved" terminal. The
status/timestamp integrity CHECK (`0055:73-76`) requires `resolved_at` non-null for every terminal status
(`arrived|stopped|cancelled|failed`); setting `resolved_at=now()` satisfies it.

### 2. Excluded from future due-arrival scans — proven
- Due-scan: `where status = 'moving' and arrive_at <= now()` (`0058:42-47`) → a `failed` row is **never
  selected**.
- Partial indexes `…_one_active_per_ship` / `…_one_active_per_fleet` / `…_due_idx` are all
  `where status = 'moving'` (`0055:80-85`) → a `failed` row **drops out** of all three.

### 3. Failure reason/code storage
**`main_ship_space_movements.terminal_reason`** — bare nullable `text`, **no CHECK** (`0055:39`; grep confirms
the only references are the column def + the S4/S5 assignments). Established convention: `'auto_arrival'`,
`'ship_destroyed'`. DOCK-0 stores an explicit code, e.g. **`'undockable_target'`** (optionally finer:
`'undockable_inactive_location'` / `'undockable_unsupported_activity'`). No enum, no schema change.

### 4. Resulting ship state is valid — proven (it is the existing S4 space-arrival settlement verbatim)
The terminal reuses the proven space-arrival mutation (`0058:98-108`): ship `status='stationary'`,
`spatial_state='in_space'`, `space_x/space_y = movement.target_x/target_y`; fleet `status='completed'`,
`location_mode='movement'`, both pointers `NULL`, `current_*` `NULL`; **no** `presence_create` call.
- **ship remains `in_space`** — `main_ship_instances_ss_in_space_status` (`0055:143-144`: in_space ⇒
  stationary) ✓; `main_ship_instances_stationary_spatial_state` (`0055:159-161`: stationary ⇒
  in_space/at_location) ✓.
- **retains valid destination coordinates** — `space_x/y = target_x/y`, already guaranteed finite + within
  `[-10000,10000]` by the movement-row CHECK (`0055:60-63`); pairing/finiteness CHECK
  (`0054:62-74`: coords non-null **iff** in_space) ✓.
- **no location presence** — the undockable path never calls `presence_create`; zero `location_presence`
  rows; the `one_active_presence_per_fleet` index (`0008:39-41`) is trivially satisfied (none created).
- **no activity** — `activity_start` (`0008:52-68`) is reached **only** via `presence_create` (`0008:88`),
  which is not called → it can never raise on this path.
- **no half-docked pointers** — fleet `active_space_movement_id` + `active_movement_id` both cleared →
  `fleets_movement_pointers_exclusive` (`0055:102-103`) ✓ and `fleets_active_space_movement_requires_moving`
  (`0055:105-109`) vacuously ✓; the `at_location` docking mutation (Q2 state + presence) is simply not run.

### 5. Cron replay cannot retry or loop — proven
After settlement: movement `failed` → excluded from the due-scan and all `status='moving'` indices (§2); fleet
`completed` → outside the lock-context active set `('idle','moving','present','returning')`
(`0056:51-53`, `0058:114-116`) so no later tick re-selects the ship for this movement; the terminal is
**single-shot**, the S3 creation receipt stays immutable. A `failed` movement with `resolved_at` set is a
permanent terminal — no path returns it to `moving`. **No retry, no loop.**

### 6. Schema support required by 0061?
**None.** `failed` already exists in the movement status domain; `terminal_reason` is already free `text` with
no CHECK; every ship/fleet constraint the terminal must satisfy already exists and is already satisfied by the
identical S4 space-arrival settlement. The terminal failure is fully representable with the current model.

### Preflight verdict
**`OSN-DOCK-0 is safe to implement with existing status model`**

*Read-only verification only — no migration or implementation written; the three planning/audit docs remain
local-only and uncommitted; DEV_LOG unaltered.*

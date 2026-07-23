# Unified-Movement Production Smoke Packet — Haven → Slagworks

> **Status: PREPARED, NOT EXECUTED.** This is a ready-to-run packet for the one outstanding
> authenticated production proof of unified fleet movement. It requires the owner to name an
> **expendable** fleet and explicitly authorise a production write. Nothing here may be executed by an
> agent, and a casual "go ahead"/"good for now" is **not** authorisation.
>
> Prepared 2026-07-23. Every figure below was read live from production; see §7 for what could not be read.

## 1. Why this exists

Unified fleet movement (`fleet_movement_unified_enabled = true` since 2026-07-17) was verified to
**classification B — evidence incomplete**. What is proven from code and live probes: exactly one
movement authority, one fleet ⇒ one movement by construction, replay is a redirect not a duplicate, and
every legacy per-ship mover is physically absent from production. What is **not** proven: any runtime
observation at all, because `fleets`, `fleet_movements`, `main_ship_instances`, `ship_groups` and
`location_presence` are RLS-scoped and return zero rows to an anonymous reader.

Closing that gap requires exactly one real movement, observed through an authenticated session.

## 2. The route, and why it is safe

**Haven → Slagworks.** Safety is **deterministic, not probabilistic**.

`pirate_intercept_evaluate_leg` (sole definition, migration `0233:377`; called by the mover at
`0233:975`) evaluates crossings *before* it rolls:

```sql
-- 0233:292-323, pirate_intercept_leg_zone_hits
from public.danger_zones z, leg
where z.status = 'active'
  and ST_Intersects(z.boundary, leg.geom)   -- leg = ST_MakeLine(origin, target)
```

If that returns no rows, the function returns `{hit:false, reason:'no_crossing'}` at `0233:431` —
**before** `random()` at `0233:446` and before the `pirate_intercepts` insert at `0233:449`.

### The separating-axis proof (read live 2026-07-23)

| | value |
|---|---|
| Haven | `(-150, -90)` — `b1a00001-0066-4a00-8a00-000000000001`, status active, `activity_type = none` |
| Slagworks | `(210, -30)` — `b1a00002-0066-4a00-8a00-000000000002`, status active, `activity_type = none` |
| Leg Y range | `[-90, -30]` → **max Y = -30** |
| Minimum Y across every vertex of every active zone | **71.955** (Reaver's lowest vertex) |
| **Separating gap on the Y axis alone** | **101.955** |
| Minimum geometric distance from leg to any zone | **149.81** |

Two sets separated on a single axis cannot intersect, so `ST_Intersects` is false for all three active
zones **regardless of polygon shape**. No shape detail, and no re-randomisation of the circle-derived
rings, can change this while the gap holds.

**The reverse leg (Slagworks → Haven) is the same segment** and is therefore equally safe.

### Active zones at time of writing

| zone | source | verts | min Y | distance to leg |
|---|---|---|---|---|
| Reaver | circle | 13 | 71.95 | 160.72 |
| Snare | circle | 20 | 80.45 | 149.81 |
| Blackden | circle | 15 | 130.57 | 160.93 |

There are **zero** standalone `drawn` zones; all three are location-backed circles.

**Zone revision numbers are NOT recorded here** because `get_danger_zones` (`0233:1372-1391`) returns
only `id, name, ring, source, location_id`. Zone `status` is implicit — the RPC filters `status='active'`
internally, byte-identically to the predicate's own filter, which is why its output *is* the evaluated
set. The `danger_zones` table itself is not readable anonymously (401: its RLS policy calls `cfg_bool`,
which anon may not execute after the `0239` lockdown).

### Routes that are NOT safe

`Haven ↔ Driftmarch` and `Driftmarch ↔ Refuge` both **cross Snare** (distance 0.0). `Refuge ↔ Lull`
clears Snare by only 23.9 units. These are intended guaranteed ambushes — see §6.

## 3. Live flag state (read 2026-07-23)

| flag | value | relevance |
|---|---|---|
| `fleet_movement_unified_enabled` | **true** | the mover is lit |
| `mainship_send_enabled` | false | legacy per-ship send retired |
| `mainship_space_movement_enabled` | false | legacy coordinate movement retired |
| `mainship_coordinate_travel_enabled` | false | free-coordinate travel off |
| `timed_docking_enabled` | **false** | a port target stays a `location` target; docking is instant, no separate 45s dock leg |
| `pirate_intercept_enabled` | **true** | interception is live — hence this route choice |
| `spatial_combat_enabled` | **true** | an interception would route into spatial combat |
| `movement_tick_seconds` | 30 | settlement cadence |
| `max_active_fleets` | 6 | fleet budget |

## 4. Canonical RPCs

| purpose | RPC | true head |
|---|---|---|
| move | `command_ship_group_go(uuid, uuid, double precision, double precision)` | `0233:589` |
| **stop / recover** | `command_ship_group_stop(uuid)` | `0218:635` |
| dock | `command_ship_group_dock(uuid)` | `0219:115` |
| multi-leg route (**do not use**) | `command_ship_group_go_route(...)` | `0233:1011` — rolls intercept **per leg** at `0233:1209` |

Client path: `commandShipGroupGo` (`src/features/command/teamApi.ts:223`), args built by
`src/features/command/teamMove.ts`. **Use the normal game UI, not a raw RPC call.** Do not enter
waypoints — that routes through `go_route`, which is the unproven path.

## 5. Expected settlement behaviour

Arrival is settled by `movement_settle_arrival` (head `0208:90`), driven by the `process-fleet-movements`
cron every **30 s** (per-row subtransaction isolation, `0206:65`).

For `target_type = 'location'` the settle calls `fleet_set_present` + `presence_create` (`0208:112-117`).
A unified fleet has `main_ship_id IS NULL`, so the ship-docking branch at `0208:134` never fires.

**Do not assume automatic docking.** The expected end state must be compared against the actual
`0208`/`0219` contract and reported as one of: *arrived at location* / *docked* / *present but undocked* /
another explicitly defined state. If the UI and backend disagree, that is a **separate frontend
synchronisation defect**, not a movement failure.

## 6. Interception is intended, not a defect

Migration `20260618000236_pirate_intercept_reliable_ambush.sql` deliberately set
`base_risk=1.0`, `min_risk=0.98`, `max_risk=1.0`, `exposure_floor=1.0` in response to an explicit owner
directive ("owner expects RELIABLE combat on entry, not a rare roll"). Any leg touching an active zone is
therefore intercepted with probability ∈ [0.98, 1.0] **regardless of fleet strength** — by design, with a
~2% escape retained deliberately. Do **not** treat this as a misconfiguration and do **not** "repair" it.

This is precisely why the smoke uses a provably non-crossing leg rather than relying on luck.

## 7. What could not be read, and why it forces a human

Anonymous reads return zero rows for `fleets`, `fleet_movements`, `ship_groups`,
`main_ship_instances`, `location_presence`, `combat_encounters`, `group_sortie_members`,
`fleet_route_legs` and `pirate_intercepts`. There is no service-role key and no access token on the
preparing machine (`.env.local` holds exactly `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`).

Consequently the fleet's *actual* position is unknown to the preparer. **If the fleet is not docked at
Haven, the origin is a different coordinate and the §2 proof does not apply** — the clearance must be
recomputed from the real origin before proceeding.

## 8. Pre-flight — re-read everything immediately before executing

Geometry and flags are runtime-mutable (`dev_zone_editor_enabled = true`; zones are editable via
`0254`/`0266`/`0268`). **Never rely on the figures in this document at execution time.**

Abort if any of the following is true:
- either location's coordinates changed;
- any zone was created, updated, reactivated or moved;
- any active zone intersects the leg;
- the World Editor is currently being used to mutate zones;
- flag state differs materially from §3;
- the group already has an active movement (the go would become a **redirect** from an interpolated
  mid-flight point, and the proof would not apply);
- the group is in combat, on a sortie, or has queued route legs.

The single decisive inequality: **minimum active-zone vertex Y must remain greater than the leg's
maximum Y (-30).**

## 9. Recovery — write this down before executing

- **Brake:** `command_ship_group_stop(p_group_id)` — cancels the live leg, holds the fleet in open space
  at the interpolated point, immediately re-commandable.
- If a pirate encounter somehow opens: **stop**. Do not issue further movement (the mover will return
  `group_on_sortie`, `0233:754-762`). Capture `combat_encounters` + `combat_units` and report.
- Do **not** re-light any legacy movement flag — the rollback is retired and doing so raises
  `column "spatial_state" does not exist` on the surviving stop function. See
  `docs/MOVEMENT_ROLLBACK_DEFECT.md`.
- Do **not** hand-edit fleet or ship movement rows.
- Do **not** test redirect/replay against the live fleet — that re-rolls interception from the
  interpolated point. That proof belongs in disposable CI.
- If no safe canonical recovery exists at execution time, **do not execute**.

## 10. Execution checklist (owner-operated)

Use an **expendable, non-critical** fleet. **Never Fleet 1** — a canary through the spatial-combat damage
path destroyed it previously (fixed by migration `0262`). Production is a live ~30-player game.

1. Record: authenticated user id, group id, unified fleet id, every member ship, command ship (if any),
   cargo, modules, current location, fleet status, current movement/combat/intercept rows.
2. Confirm: no active movement (`active_movement_id` null), no active combat, no sortie membership, no
   queued `fleet_route_legs`, no unresolved intercept, no ambiguous duplicate unified fleet row.
3. Confirm origin is Haven (`current_location_id = b1a00001-…`, status `present`).
4. Re-run §8 pre-flight against live data.
5. Issue **exactly one** movement through the game UI: select the group, tap Slagworks, confirm Go.
6. Capture from the network trace: UI action, client function, RPC name, request body, request id,
   response envelope, timestamp, `fleet_id`, `movement_id`, `arrive_at`, `member_count`,
   `redirected` (**must be false**), `origin_type`/`target_type` (**both `location`**).
7. Confirm the client called `command_ship_group_go` and **no retired wrapper or RPC**.
8. Confirm exactly one `fleet_movements` row with `status='moving'` for the unified fleet, and that every
   per-member fleet is `completed`/absent.
9. **Confirm no `pirate_intercepts` row exists for this `movement_id`.** The insert at `0233:449` runs for
   *misses as well as hits*, so **absence** proves the `no_crossing` exit was taken. A row here — even
   `hit=false` — means the leg crossed a zone; abort and re-audit the geometry.
10. Wait through at least **two** 30-second settlement cycles. Issue no other command.
11. Confirm arrival: movement `completed` with `resolved_at` set; fleet `present` at Slagworks;
    `active_movement_id` null; one active `location_presence`; all members share the one authoritative
    state; no duplicate movement; no stale movement.
12. Confirm no combat and no intercept row appeared versus the step-1 baseline.
13. Confirm the UI refreshed to the correct final state (poll interval is 4000 ms,
    `useGalaxyMapData.ts:319`).

## 11. Classification

- **PASS** — the full UI-to-arrival chain succeeded and the authenticated state proves every condition in
  §10. Only then may the movement documentation record that unified movement is
  authenticated-production-smoked, with exact timestamp and evidence identifiers.
- **BACKEND PASS / UI FAIL** — canonical movement succeeded but the player-facing UI is unavailable,
  incorrect, stale, or calls a removed RPC. Open a focused frontend repair PR; do not repeat the
  production write until that repair is deployed.
- **FAIL** — movement rejected unexpectedly, duplicated state, failed to settle, produced inconsistent
  ship state, or routed into combat despite the proven non-crossing geometry. Stop all further production
  movement tests and prepare the smallest dark correction. **Do not restore legacy flags.**

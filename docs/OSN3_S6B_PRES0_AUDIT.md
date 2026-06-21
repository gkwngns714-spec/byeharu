# OSN-3 S6B-PRES-0 — Legacy → OSN-Only Cutover Audit (Clean-Cut)
## Reconnaissance Charter (local-only)

> **Status: RECONNAISSANCE ONLY.** No code, migration, coordinate change, flag change, renderer switch,
> deletion, commit, push, S6C/S6D/OSN-4. Baseline: `main == origin/main == 3c7e7a8`; S6B closed;
> `mainship_send_enabled=true`, `mainship_space_movement_enabled=false`; S6A dark. Pre-launch dev project.

## Locked direction — OSN-ONLY end state (no long-term legacy compatibility)
The final Byeharu architecture contains exactly: **one canonical fixed galaxy coordinate system; one fixed
map renderer; one main-ship movement engine (OSN); one arrival interpretation layer.** It contains **none
of:** `buildNormalizer()` · content-derived dynamic bounds · `legacy_dynamic` · the old main-ship
send/return/direct-move route · old main-ship-specific travel UI · any temporary coordinate bridge after
cutover · obsolete legacy verifier/workflow/docs. Old `x∈[9,33]/y∈[4,23]` location values are **prototype
data**, replaced by a **hand-designed canonical galaxy**. Reusable game concepts are kept **only where they
still make sense** (named locations, home/base, main-ship ownership/hulls/repair, combat/rewards/resources,
generic fleet infra **iff independently useful**). **No old implementation is preserved merely because it
exists.** (Uniform-scaling / timing-preservation options are superseded and removed.)

> **Decisive fact (now a design lever, not a constraint):** travel time = `f(coordinate distance)`
> (`movement_create` `movement_system.sql:105-106`; the OSN writer `0057:179-180` uses the identical
> formula). The canonical galaxy's distance bands × speed × `travel_scale` **define** trip durations.

---

## A. Disposition inventory (every legacy coordinate / movement / map / arrival dependency)

Disposition keys: **R** = retain as reusable domain concept (may need OSN-based reimplementation) ·
**O** = replace with OSN implementation (required behavior rebuilt before cutover) · **X** = retire
completely (removed after replacement).

| Dependency (file:line) | What it is | Disp. | Notes |
|---|---|---|---|
| Named locations (`locations` entities + gameplay) | hunt/mine/trade/combat/reward targets | **R** | concept stays; coordinate VALUES replaced by canonical galaxy |
| Prototype location coords `9-33 / 4-23` (`world_map.sql:151-162`) | seed data | **X** | discard; replaced by hand-designed canonical seed |
| Home/base (`bases`, `(0,0)`) | player origin | **R** | home stays `(0,0)` |
| Main-ship ownership / hulls / repair (`main_ship_instances`, `main_ship_hull_types`, `repair_main_ship`) | ship identity | **R** | concept stays (repair may be reimplemented as real recovery) |
| Combat / rewards / resources / world-state / ownership / `location_presence` | core gameplay | **R** | untouched |
| Fixed renderer (`openSpaceTransform` + S6B markers + camera + `FleetMovementLine` + `LocationMarker`) | the ONE renderer | **R** | already built (S6B); becomes the only renderer |
| `resolve_fleet_movement_speed` (`0051`) | speed resolver | **R** | shared by OSN + fleets |
| Generic unit-fleet infra (`send_fleet_to_location` `0010`, `fleet_units`, `fleet_speed` `0006`) | OGame-style fleets | **R?** | **retain ONLY if independently useful (product decision — see §C.3); else X**. Must be SEPARATED from the main ship regardless |
| Movement spine (`movement_create` `0007`, `process_fleet_movements` `0009`, `fleet_movements`) | generic travel spine | **R?/O** | shared: **retain for unit fleets if kept**; the **main-ship** uses of it are **O→X**. Main ship must stop using `movement_create`/`fleet_movements`/`active_movement_id` |
| Legacy main-ship outbound `send_main_ship_expedition` `0050:138` | main-ship → location | **O → X** | OSN command-to-coordinate replaces it |
| Legacy main-ship A→B `move_main_ship_to_location` `0053` | location→location | **O → X** | OSN re-command from `in_space` replaces it |
| Legacy main-ship recall `request_main_ship_return` `0050:215` | location→home | **O → X** | OSN command to `(0,0)` replaces it |
| Legacy main-ship reconciler `process_mainship_expeditions` `0050` (cron) | status sync | **O → X** | S4 `process_mainship_space_arrivals` is the OSN analogue |
| **Arrival interpretation** — legacy `process_fleet_movements` → **`present` at location** vs OSN S4 → **`in_space`** | two arrival meanings | **O** | the ONE OSN arrival layer must gain **location-docking** (the blocker — §C.1.d) |
| Legacy main-ship UI (`MainShipCommand` send/move, `MainShipPreview` recall) | travel UI | **O → X** | OSN command UI replaces; keep only ship-status display |
| Legacy client API (`mainshipApi.ts` `sendMainShipExpedition`/`moveMainShipToLocation`/`requestMainShipReturn`) | client calls | **X** | after UI removed |
| `travelPreview.ts:9 distance()` | legacy send preview | **X** | retire with legacy send UI |
| `buildNormalizer` / `norm` / dynamic content-bounds (`GalaxyMap.tsx:21-86`) | prototype renderer | **X** | fixed renderer already replaces it |
| `legacy_dynamic` + `coordinateSpace` discriminant + resolver §D/§E/§F (`resolveMainShipMarker.ts`) | legacy render routing | **X** | retire in the renderer cleanup (PRES-5) |
| `mainship_send_enabled` flag + `dev-mainship-flag.mjs/.yml` | legacy gate + tooling | **X** | after cutover |
| Legacy main-ship verifiers/fixtures/workflows (`verify-mainship-send/move/repair*`) | tests | **X** | after OSN proof |
| Range / proximity / combat targeting on coords | — | n/a | **none exist** — no distance-gated gameplay anywhere |

---

## B. Active / test / history data at cutover (pre-launch → discardable)
- **Prototype location/base coords:** discard, replace with canonical seed.
- **Active `fleet_movements` (main-ship + unit), in-flight endpoints:** **reset** (dev pre-launch) — no
  preservation, **no coordinate bridge** (the final architecture forbids a residual bridge).
- **Historical/terminal rows, snapshots:** **discardable** — no real-player history-retention obligation
  (pre-launch). Archive only if a designer wants prototype telemetry (optional, out of band).
- **Coordinate-domain (`main_ship_space_movements`):** empty/dark — untouched.
- **Test fixtures:** coordinate-domain fixtures use **synthetic** coords (unaffected); the world-map seed +
  any real-coord-reading fixture are rewritten for the canonical galaxy; legacy main-ship fixtures retire
  with the legacy route.

---

## C. Required identifications

### C.1 Everything that must be REPLACED before the old main-ship route can be disabled (OSN gaps)
1. **Player command surface (S6C):** select/confirm a destination → call the S6A wrapper
   `command_main_ship_space_move`; a recall-to-`(0,0)` affordance.
2. **Named-location targeting:** translate a chosen location → its canonical coordinate as the OSN target.
3. **Controlled enablement (S6D):** flip `mainship_space_movement_enabled` on (reversible) after proofs.
4. **⭐ Arrival-at-location → docking/presence (the ONE arrival interpretation layer):** legacy travel ends
   `present` at a location (which unlocks hunt/mine/trade/combat/rewards); OSN arrival ends `in_space`
   (proximity ≠ docked). The OSN arrival layer must establish location-presence on arriving at a location's
   coordinate. **The old main-ship route cannot be disabled until this exists** — else the main ship loses
   location gameplay.
5. **(Optional) OSN-4 Stop** (mid-travel halt) — QoL, not a cutover blocker.
6. **Acceptance parity:** OSN send → travel → arrive → **dock** → recall, all proven, before the flag flip.

### C.2 Everything DELETABLE immediately after replacement
After OSN main-ship travel + docking are live and the legacy flag is OFF and unreferenced: the four legacy
main-ship RPCs + reconciler; legacy main-ship UI bits + client API fns + `travelPreview.distance`;
`mainship_send_enabled` + `dev-mainship-flag.*`; `buildNormalizer`/`norm`/`PAD` + `legacy_dynamic` +
`coordinateSpace` + resolver §D/§E/§F; legacy main-ship verifiers/workflows/fixtures; the prototype seed
path. (All are **X** in §A.)

### C.3 Shared systems that must be SEPARATED before legacy deletion (no collateral breakage)
- **`fleets` table + `main_ship_id` tag + movement-pointer columns:** both legacy main-ship travel
  (`active_movement_id` → `fleet_movements`) and OSN (`active_space_movement_id` → `main_ship_space_movements`)
  attach a main-ship fleet. **Separate:** the main ship must use **only** the OSN pointer post-cutover; the
  `fleets`/tag stay (OSN uses them). Verify no main-ship fleet references the legacy movement pointer before
  deleting the legacy path.
- **Movement spine (`movement_create`/`fleet_movements`/`process_fleet_movements`):** shared with **unit
  fleets**. **Separate:** decouple the main ship from `movement_create` (it uses
  `mainship_space_begin_move`); the spine **stays only if unit fleets stay** (C.3 decision below).
- **`resolve_fleet_movement_speed`:** shared (OSN main-ship hull speed + unit fleets) → **retain**.
- **`MainShipCommand`/`MainShipPreview`/`mainshipApi`:** mix legacy travel + still-useful status/HP/repair
  display. **Separate** the display (retain) from the legacy travel commands (retire).
- **⚠ PRODUCT DECISION — do unit fleets survive?** The final game (Main Ship + Captains + Modules + Support
  Craft) may not keep OGame-style disposable **unit fleets**. If unit fleets are **not** independently
  useful, the entire generic spine (`send_fleet_to_location`, `fleet_units`, `fleet_speed`,
  `movement_create`, `process_fleet_movements`, `fleet_movements`) becomes **X** too — a much larger
  retirement. **This decision gates how much of the "shared" infrastructure is retained vs retired.**

### C.4 Exact deletion ORDER (leaves no dead references)
Build-then-cut, callers-before-callees:
1. **Build OSN replacements** (C.1: command surface, location targeting, docking arrival layer, recall),
   additive + dark/flag-gated + proven. *(No deletion yet.)*
2. **Reset + reseed** the canonical galaxy (data); clear active legacy movements.
3. **Cutover flip:** OSN on (`mainship_space_movement_enabled=true`), legacy main-ship route off
   (`mainship_send_enabled=false`). *(Legacy RPCs now unreachable but still present.)*
4. **Remove legacy main-ship UI** (`MainShipCommand` send/move, `MainShipPreview` recall) — kills the
   client callers first.
5. **Remove legacy client API fns** (`sendMainShipExpedition`/`moveMainShipToLocation`/
   `requestMainShipReturn`, `travelPreview.distance`) — now uncalled.
6. **Remove legacy main-ship RPCs** via migration (`send_main_ship_expedition`,
   `move_main_ship_to_location`, `request_main_ship_return`, `process_mainship_expeditions` + cron) — drop
   from the canonical grant block; now uncalled by the client.
7. **Remove `mainship_send_enabled` + `dev-mainship-flag.*`** — flag now unused.
8. **Renderer cutover:** swap the 4 `GalaxyMap` `norm(...)` sites → `worldToViewBox`; remove resolver
   §D/§E/§F `legacy_dynamic` branches; collapse `coordinateSpace`; delete `buildNormalizer`/`PAD`. *(The
   `MainShipMarker` `legacy_dynamic` arm goes last, after no marker can produce it.)*
9. **Remove legacy main-ship verifiers/workflows/fixtures** + prototype-seed references.
10. **(If unit fleets retired)** separately remove the generic spine after confirming no consumer remains.
11. **Docs:** update DEV_LOG/GUIDE; remove obsolete legacy references; supersede stale charter/recon notes.

*Invariant at every step: nothing deleted while a live reference exists (UI → API → RPC → flag → renderer).*

---

## D. Final-architecture target (one of each)
| Layer | The ONE | Replaces / retires |
|---|---|---|
| Coordinate system | canonical `[-10000,10000]²`, home `(0,0)` | prototype `9-33/4-23` |
| Map renderer | `openSpaceTransform` (`worldToViewBox`) + camera | `buildNormalizer`/`norm`/dynamic bounds/`legacy_dynamic` |
| Main-ship movement engine | OSN (`command_main_ship_space_move` → `mainship_space_begin_move`) | `send_main_ship_expedition`/`move_main_ship_to_location`/`request_main_ship_return` |
| Arrival interpretation | OSN arrival layer (`in_space` **+ location-docking**) | legacy `process_fleet_movements` main-ship presence + `process_mainship_expeditions` |

---

## E. Answers to the six questions
1. **Replace before disabling the old route:** C.1 — command surface (S6C), location targeting, enablement
   (S6D), and **arrival→docking** (the blocker), with acceptance parity.
2. **Deletable immediately after replacement:** C.2 — legacy main-ship RPCs/UI/API/flag/tooling + the
   prototype renderer (`buildNormalizer`/`legacy_dynamic`/`coordinateSpace`) + legacy main-ship tests.
3. **Shared systems to separate first:** C.3 — `fleets`/`main_ship_id`/movement-pointers; the movement
   spine; `resolve_fleet_movement_speed`; the mixed UI/API surfaces — **plus the unit-fleet survival
   decision** that sets how much spine is retained.
4. **Data at cutover:** B — reset/discard (pre-launch); no bridge; archive optional.
5. **Deletion order:** C.4 — build → reset → cutover-flip → UI → API → RPC → flag → renderer → tests →
   (spine) → docs.
6. **Smallest first implementation slice toward OSN-only:** **PRES-1 — Canonical galaxy seed (clean
   reset)** (below). Foundational, invisible, unblocks both the renderer cutover and OSN location-targeting.

### Smallest first slice — PRES-1: Canonical galaxy seed (clean reset)
**Prerequisite (design, not code):** agree the concrete canonical coordinates (distance bands below).
**Then** one forward migration **replaces** location/base coordinates with the hand-designed canonical
values in `[-10000,10000]` (home `(0,0)`) and **resets** active legacy main-ship movements; optionally adds
finite + range CHECK constraints. **No renderer switch, no flag change, no deletion, no command path, no
bridge** — `buildNormalizer` still fits whatever bounds exist, so the map stays usable and **looks
unchanged** until the renderer cutover. **Proof:** disposable-Postgres real-chain (all locations/bases in
`[-10000,10000]`; fresh-DB seed→reseed consistent; `build` green; legacy + OSN verifiers green) + read-only
live spot-check (coords in-domain, flags unchanged). It is the minimal, reversible foundation for every
later OSN-only step.

**Canonical galaxy-design input packet (framework, not final coords):** domain `[-10000,10000]²`, home
`(0,0)`; **starter** band `r≈500–2,500`, **mid-game** `r≈2,500–6,500`, **outer/exploration** `r≈6,500–9,500`
(edge margin); hand-placed (deterministic), difficulty/reward ↑ with distance, inter-location gaps ≳ a few
hundred world units (visually distinct at min zoom), open space between locations; pick band radii together
with `speed`/`travel_scale` to set the desired starter trip duration (`≈ r / speed × travel_scale`, floored
at `min_travel_seconds`).

---

*Reconnaissance only — no code, migration, coordinate change, flag change, deletion, or production change.
Awaiting (a) the unit-fleet survival decision (C.3), (b) the canonical galaxy coordinate set, and (c) an
explicit "begin PRES-1". S6C must not begin before the OSN command + docking replacements are chartered;
S6D stays blocked until the unified renderer + OSN main-ship travel (incl. docking) are complete + approved.*

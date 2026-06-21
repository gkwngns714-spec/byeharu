# OSN-3 S6B2 — Fixed-Space Ship Rendering via Coordinate Provenance
## Reconnaissance Charter (local-only)

> **Status: RECONNAISSANCE ONLY.** No code, migration, RPC, flag, S6A change, commit, or push. Ends with
> a concrete implementation boundary that is **not** executed. Baseline frozen: `main == origin/main` at
> `586d67c`; S6A deployed + dark; `mainship_send_enabled=true`, `mainship_space_movement_enabled=false`;
> S6B1 fixed transform (`src/features/map/openSpaceTransform.ts`) merged + verified.

## Goal
Render **only the main ship's open-space states** (`in_space`, coordinate `in_transit`) through the S6B1
fixed-domain transform, tagged by a discriminated `coordinateSpace: 'legacy_dynamic' | 'open_space_fixed'`.
All legacy named-location visuals, legacy movement/return, `buildNormalizer()`, and every named-location
marker stay **unchanged**. Because coordinate movement is production-dark, the S6B2 **production visual
effect must be zero**.

---

## A. Verified data flow — fetched data → rendered ship marker (frozen `586d67c`)

```
useGalaxyMapData (poll ~4s)
  ├─ fetchMainShip()                    → mainShip {status, spatial_state, space_x, space_y, …}   (main_ship_instances)
  ├─ fetchActiveMainShipFleet()         → mainShipFleet {status, location_mode, active_movement_id,
  │                                        active_space_movement_id, current_location_id}          (fleets)
  ├─ fetchActiveMainShipPresence()      → mainShipPresence {status, fleet_id, location_id}         (location_presence)
  ├─ fetchActiveMainShipSpaceMovement() → mainShipSpaceMovement {origin_x/y, target_x/y,
  │                                        target_kind, depart_at, arrive_at, status='moving'}     (main_ship_space_movements)
  └─ movements[]                        → legacy FleetMovement rows                                (fleet_movements)
         │
         ▼
GalaxyMap.tsx (passes all of the above into MainShipMarker.inputs; flag-gated by mainshipSendEnabled)
         │
         ▼
MainShipMarker.tsx ── resolveMainShipMarker(inputs, now) → ShipMarker {x,y (WORLD), state} | null
         │                                                   then: norm({x,y}) → SVG [0..1000] (line 34)
         ▼
   <polygon> inside GalaxyMap's camera <g transform="translate(tx ty) scale(k)">
```

**Call sites that construct/consume marker coordinates (exhaustive):**
- **Construct:** `resolveMainShipMarker` (`resolveMainShipMarker.ts:40`, the single position source of truth)
  — the `make(state,x,y)` helper (`:43`) builds every `ShipMarker`.
- **Consume:** `MainShipMarker.tsx:34` — `const p = norm({ x: marker.x, y: marker.y })` — **the ONLY
  consumer of marker coordinates.** (`GalaxyMap.tsx:222` renders `MainShipMarker` but does not call the
  resolver or read marker coords; `LocationMarker`/`FleetMovementLine` never touch ship marker coords.)
- The resolver is also imported by the pure test `tests/resolveMainShipMarker.spec.ts`.

→ **The entire routing boundary is two files:** `resolveMainShipMarker.ts` (set provenance) and
`MainShipMarker.tsx` (route the transform). Nothing else needs to know about coordinate space.

### Interpolation today
- **`in_space` (`§B`, `:61-68`):** position = `mainShip.space_x/space_y` (WORLD); no interpolation.
- **Coordinate `in_transit` (`§C`, `:71-91`):** interpolates `spaceMovement.origin_(x,y) → target_(x,y)`
  by `t = clamp01((now − depart)/(arrive − depart))` **in WORLD space**; returns WORLD `x,y`.
- **Legacy travel/return (`§F`, `:120-149`):** interpolates a `fleet_movements` row in WORLD space;
  returns WORLD `x,y`.
- **`MainShipMarker`** runs a 1 s `setInterval` tick only while `state ∈ {outbound, returning}` (`:27-31`).

### Distinguishing coordinate vs legacy `in_transit` — PROVEN from data flow, not assumed
`'in_transit'` is a value of **`main_ship_instances.spatial_state`** (`mainshipApi.ts:18`
`SpatialState = 'home'|'at_location'|'in_transit'|'in_space'|'destroyed'`). It is written **only** by the
S3 coordinate writer `mainship_space_begin_move` (migration 0057) and cleared by the S4 arrival processor
(0058). **Legacy travel never sets `spatial_state`** — a legacy main-ship expedition leaves
`spatial_state = NULL` and uses `main_ship_instances.status='traveling'` + a `fleet_movements` row.
Therefore:
- **coordinate transit** ⟺ `spatial_state === 'in_transit'` **and** a coherent active `spaceMovement`
  (`main_ship_space_movements`) row linked to the fleet (resolver `§C` enforces the full coherence chain,
  `:71-91`).
- **legacy transit** ⟺ `spatial_state === null` **and** `fleet.status ∈ {moving,returning}` **and** a
  `fleet_movements` `status='moving'` row (resolver `§F`, `:120-133`).

The marker `state` enum is **NOT** sufficient — `§C` and `§F` both return `'outbound'`/`'returning'`. So
provenance must be assigned **per resolver branch**, not derived from `state`.

---

## B. Routing matrix

| Ship state / source (resolver branch) | `spatial_state` + key signal | `coordinateSpace` | Transform | Existing behavior preserved? |
|---|---|---|---|---|
| Home — new `home` (`§E`) or legacy null-home (`§F`) | `'home'` / `null`, no fleet, base coords | `legacy_dynamic` | `buildNormalizer` | **yes** |
| At named location — `at_location` (`§D`) / `legacy_present` (`§F`) | `'at_location'` / `null` + present fleet + presence | `legacy_dynamic` | `buildNormalizer` | **yes** |
| Legacy named travel/return (`§F`) | `null` + fleet moving/returning + `fleet_movements` | `legacy_dynamic` | `buildNormalizer` | **yes** |
| `in_space` (`§B`) | `'in_space'` + ship `space_x/space_y` | `open_space_fixed` | **S6B1 fixed** | **new, dark** |
| Coordinate `in_transit` (`§C`) | `'in_transit'` + coherent `spaceMovement` | `open_space_fixed` | **S6B1 fixed** | **new, dark** |
| Destroyed / contradictory-destroyed (`§A`) | `status/ss = 'destroyed'` | — (resolver returns `null`) | none rendered | **explicit: no marker** |
| Unknown / malformed / incoherent (`§G`, or any branch failing a guard) | any | — (resolver returns `null`) | none rendered | **explicit: no marker** |

Notes: "repair-required" is the `destroyed` ship state → `§A` → `null` (no marker, no accidental fixed
rendering). "Unavailable"/stale/missing-movement → the relevant branch's coherence guards return `null`
(e.g. `§C` returns `null` if `spaceMovement` is missing/incoherent or `arrive ≤ depart`). **No branch may
emit a marker without an explicit `coordinateSpace`.**

---

## C. Provenance contract

**Field (exactly as mandated):**
```ts
// in resolveMainShipMarker.ts — added to the resolved marker model (single source of position truth)
export type CoordinateSpace = 'legacy_dynamic' | 'open_space_fixed'
export interface ShipMarker {
  entityId: string
  entityType: 'main_ship'
  relation: 'self'
  x: number // WORLD
  y: number // WORLD
  state: MainShipMarkerState
  coordinateSpace: CoordinateSpace // NEW — which transform layer renders this marker
}
```

**Where it lives — the resolved marker model (`ShipMarker`).** The resolver is the only code that knows
which branch produced the marker, and `MainShipMarker` is the only consumer. So provenance belongs on
`ShipMarker` — **not** in render props, **not** in a separate union threaded through `GalaxyMap`, and
**not** in `LocationMarker` (location markers gain no coordinate-space knowledge).

**Enforcing exhaustiveness / no silent legacy fallback:**
- The `make()` helper is changed to **require** `coordinateSpace` as a parameter:
  `make(state, coordinateSpace, x, y)`. A resolver branch that returns a marker **must** name its space —
  omitting it is a compile error. `§B/§C` pass `'open_space_fixed'`; `§D/§E/§F` pass `'legacy_dynamic'`.
- `MainShipMarker` routes with an **exhaustive switch** and a `never` guard (no `default → legacy`):
  ```ts
  function pickViewBox(m: ShipMarker, norm: (p:{x:number;y:number})=>{x:number;y:number}) {
    switch (m.coordinateSpace) {
      case 'legacy_dynamic':   return norm({ x: m.x, y: m.y })
      case 'open_space_fixed': return worldToViewBox({ x: m.x, y: m.y }) // from S6B1
      default: { const _exhaustive: never = m.coordinateSpace; throw new Error(`unhandled coordinateSpace ${_exhaustive}`) }
    }
  }
  ```
  Adding a future provenance value without handling it becomes a **type error**; an impossible runtime
  value throws rather than silently rendering through `buildNormalizer()`.
- **Impossible to pass a coordinate marker through `buildNormalizer()` by accident:** `norm` is applied
  **only** in the `legacy_dynamic` arm; `open_space_fixed` is the only arm that can reach the ship's world
  coords and it uses `worldToViewBox`. Since `MainShipMarker` is the sole consumer, there is no other path.
- **Legacy marker shape/API preserved:** `ShipMarker` gains one field; `MainShipMarkerState`, the
  `make()` outputs, and all legacy branch logic are otherwise unchanged. `GalaxyMap`/`LocationMarker`/
  `FleetMovementLine` are untouched.

---

## D. Fixed rendering contract

- **viewBox-local before the camera `<g>`:** `worldToViewBox` outputs `[0..1000]` viewBox-local coords —
  exactly the space `norm` outputs — so the open-space ship renders **inside the existing camera `<g>`**,
  and the existing `translate(tx ty) scale(k)` applies pan/zoom for free. The **only** difference between
  layers is the world→viewBox function; the camera is shared, unchanged.
- **`in_space` position:** taken from `mainShip.space_x/space_y` (resolver `§B`) — already WORLD coords.
- **Coordinate-transit interpolation:** **already computed in WORLD space** by resolver `§C`
  (origin→target by time `t`), returning WORLD `x,y`. S6B2 changes **nothing** about the interpolation —
  it only routes the resulting WORLD coord through `worldToViewBox` instead of `norm`.
- **Interpolation order = world space, then `worldToViewBox`, then camera (the preferred order, and the
  current reality).** Why correct: (1) it matches the future input inversion — `screenToWorld` returns
  WORLD, and the command path is WORLD, so keeping one WORLD source of truth makes render and future
  command symmetric; (2) `worldToViewBox` is affine, so world-space interpolation + transform is
  numerically equivalent to viewBox-space interpolation, but world-space keeps the semantics auditable;
  (3) no source constraint forces viewBox-space interpolation — the resolver already produces world coords.
- **No drift vs a future fixed-space preview:** the S6B3 preview will use the **same** `worldToViewBox`
  + the same camera `<g>`, so ship and preview share one mapping → zero relative drift.
- **Absent/stale active-movement data is safe:** `§C` returns `null` when `spaceMovement` is
  missing/incoherent, non-finite, or `arrive ≤ depart`; `§B` returns `null` for non-finite `space_x/y`.
  A `null` marker hides the ship — it never renders a wrong/last-known position.

---

## E. No-co-registration guardrail (restated + applied to S6B2)
- The fixed open-space ship layer is **not** visually co-registered with dynamically-normalized named
  locations merely because they share the camera `<g>`. S6B2 is a **dark proof layer only**.
- Do **not** make named locations look like navigational landmarks for the fixed ship; do **not** change
  any named-location position "to make it look right"; do **not** add text/UI implying physical
  distance/relationship between the fixed ship and named locations.
- **S6B-PRES** remains the mandatory future owner of the fixed-space ↔ named-location presentation
  decision and **must** land before any **S6D** production enablement.
- Because open-space states are production-dark, on live data the ship marker is **always**
  `coordinateSpace='legacy_dynamic'` → `MainShipMarker` never takes the fixed arm → **zero production
  visual change** (this is itself an assertion in F).

---

## F. Read-only proof & testing plan (for the later implementation)
- **Pure resolver provenance tests** (extend `tests/resolveMainShipMarker.spec.ts`): every existing branch
  case additionally asserts `coordinateSpace` — home/at_location/legacy travel/return/present →
  `'legacy_dynamic'`; `in_space` + coordinate `in_transit` → `'open_space_fixed'`.
- **Legacy routing unchanged:** assert every legacy state still resolves `'legacy_dynamic'` (→ rendered
  via `buildNormalizer`), and that legacy x/y outputs are byte-identical to today (positions already
  asserted; add the provenance field).
- **Open-space routing isolation:** assert `in_space` and coordinate transit resolve `'open_space_fixed'`
  and **only** these.
- **Coordinate-transit interpolation boundaries:** `t=0` (start=origin), `t=0.5` (midpoint), `t=1`
  (end=target), and stale/missing/incoherent movement → `null` (no marker).
- **Type-level exhaustiveness:** the `MainShipMarker` `never` switch guarantees an unrecognized
  provenance is a compile error (and throws at runtime if forced).
- **No production-visible difference (flag false):** a test over production-shaped data (no `in_space`/
  coordinate `in_transit`) asserts `coordinateSpace` is always `'legacy_dynamic'` → fixed arm unreached.
- **Map rendering smoke under pan/zoom:** a browser visual check that the open-space ship renders through
  the fixed transform and co-moves under camera — **deferred to S6B3** (see boundary), since it needs DOM
  and pairs naturally with the preview proof.
- **Build/typecheck** (`tsc -b` + `vite build`) + the existing resolver verification. **No migration, no
  live-DB test** — S6B2 changes no server behavior.

---

## G. Proposed implementation boundary (NOT executed)
- **Files likely to change (two):**
  - `src/features/map/resolveMainShipMarker.ts` — add `CoordinateSpace` + the `coordinateSpace` field;
    make `make()` require it; set `'open_space_fixed'` in `§B/§C`, `'legacy_dynamic'` in `§D/§E/§F`.
  - `src/features/map/MainShipMarker.tsx` — import `worldToViewBox` from `openSpaceTransform`; replace the
    single `norm(...)` call with the exhaustive `coordinateSpace` switch (legacy→`norm`, fixed→
    `worldToViewBox`, `never` guard). No visual/colour/shape change.
- **Files that must NOT change:** `GalaxyMap.tsx` (still passes `norm`; no edit needed), `buildNormalizer`/
  the legacy `norm` logic, `LocationMarker.tsx`, `FleetMovementLine.tsx`, `useGalaxyMapData.ts`,
  `mainshipApi.ts` (data already fetched), **`openSpaceTransform.ts` (frozen S6B1 — reused, not modified)**,
  any `supabase/migrations/**`, any RPC, all S6A artifacts, all flags.
- **Resolver test:** **extend** `tests/resolveMainShipMarker.spec.ts` (it already exercises every branch;
  adding provenance assertions is the minimal, cohesive change). A new resolver test file is **not** needed.
- **Workflow:** **reuse the existing `verify-osn-resolver` path** — the extended spec runs under
  `npm run verify:osn:resolver`. Gating options for the S6B2 PR: (a) **dispatch** `verify-osn-resolver`
  on the branch (it already exists on `main`, so it is dispatchable — **no workflow edit**), plus
  `build.yml` on the PR; or (b) add a path-scoped `pull_request` trigger to `verify-osn-resolver.yml`
  (a one-line `on:` addition) — but this **modifies an existing workflow**, which prior guidance fenced
  off, so it would need **explicit approval**. **Recommended: (a)** — no new workflow, no existing-workflow
  edit. A dedicated S6B2 workflow is **not** needed.
- **Development-only visual proof:** **deferred to S6B3.** S6B2 = resolver provenance + `MainShipMarker`
  routing + pure/type tests + typecheck. The on-screen "ship renders via the fixed transform and co-moves"
  visual belongs with S6B3's read-only preview (both are dev-gated, DOM-level, and share `worldToViewBox`).
- **Acceptance criteria:** every legacy state → `legacy_dynamic` (positions unchanged); `in_space` +
  coordinate `in_transit` → `open_space_fixed` (rendered via `worldToViewBox`); exhaustive switch with no
  silent legacy fallback; production-shaped data never takes the fixed arm (zero prod visual change);
  `verify:osn:resolver` + `build` green; flags unchanged; no migration/live-DB run.
- **Deliberate exclusions:** no preview (S6B3), no tap/`mapToWorld` wiring (S6C), no command/CTA/RPC/flag
  (S6C/S6D), no named-location co-registration (S6B-PRES), no `GalaxyMap`/`LocationMarker`/`buildNormalizer`
  change, no backend change, no colour/shape/visual restyle of the ship marker.

*Reconnaissance only — no code. Awaiting an explicit "begin S6B2" instruction.*

# OSN-3 S6B-PRES — Unified Fixed-Domain Map Rendering
## Reconnaissance Charter (local-only)

> **Status: RECONNAISSANCE ONLY.** No code, migration, flag, server, or S6A/S6B change; no commit/push.
> Ends with decisions + a recommended first slice that are **not** executed. Baseline frozen:
> `main == origin/main == 3c7e7a8`; S6B fully closed; `mainship_send_enabled=true`,
> `mainship_space_movement_enabled=false`; S6A command boundary dark.

## Product direction — LOCKED
Retire the legacy **dynamic** map-rendering system and unify the entire visible world onto **one
canonical fixed coordinate domain** `x,y ∈ [-10000, 10000]`, so every visible entity renders:
`world → worldToViewBox() → existing camera <g> → SVG viewBox → screen`. This is a **frontend
spatial-rendering unification**, *not* a removal of named-location gameplay. **Preserve** named locations,
named-location travel, legacy send/return/recall, direct movement, repair, ownership/presence,
combat/reward, and all backend travel behavior. The thing to eventually retire is **`buildNormalizer()`**,
its **content-derived dynamic bounds**, and **`legacy_dynamic`** visual placement.

> ### ⚠ HEADLINE FINDING (the whole charter pivots on this)
> **Existing world coordinates are NOT in `[-10000,10000]` — they are a tiny cluster.** Named locations
> are hardcoded in **`[9,33] × [4,23]`** (`world_map.sql:151-162`); base is **`(0,0)`**; legacy movements
> inherit location coords. `buildNormalizer` *fits* this cluster to the viewBox dynamically, so it looks
> fine today. The fixed `worldToViewBox` maps `[-10000,10000]→[0,1000]` at scale **0.05**, so the current
> world (≈24-unit spread) would render as a **~1.2-px dot near (500,500)** — unusable. **Therefore
> unification is NOT a transform swap; it REQUIRES a coordinate-data step first (PRES-1).**

---

## A. Canonical coordinate audit (verified from schema + seed + source)

| Entity | Coordinate source (file:line) | Unit / actual range | Axis | In `[-10000,10000]`? | Gap / required work |
|---|---|---|---|---|---|
| **Named locations** | `supabase/migrations/20260616000002_world_map.sql:48-72` (cols), `:151-162` (seed) | `double precision`; **seeded `x∈[9,33] y∈[4,23]`**; **no CHECK** | +y = north (up) | **NO — tiny cluster** | **Reseed/rescale into canonical coords with real spread; (optional) add bounds CHECK** |
| **Player home/base** | `20260616000005_base_system.sql:10-19` (cols), `:141` (`initialize_new_player` → `(0,0)`) | `double precision`, default `(0,0)`; **no CHECK** | same | **(0,0) in range** | Value OK; decide if `(0,0)` is the canonical home or per-player; (optional) CHECK |
| **Legacy movement origin** | `20260616000007_movement_system.sql:18-19`; values from `base.x/y` or `location.x/y` (`send_*` RPCs) | `double precision`; base→`(0,0)`, location→`[9,33]`; **no CHECK** | same | **mixed** | Inherits location fix; no independent work if locations fixed |
| **Legacy movement destination** | same table `:25-26`; values from `location.x/y` | `double precision`; `[9,33]×[4,23]`; **no CHECK** | same | **NO** | Inherits location fix |
| **Return-home endpoints** | `request_main_ship_return` / movement_create → base `(0,0)` | `double precision`; `(0,0)` | same | **yes** | none |
| **Movement lines** | rendered from movement origin/target (above) | derived | same | follows movements | follows locations/base |
| **Location labels / static content** | rendered from location x/y (above) | derived | same | follows locations | follows locations |
| **Coordinate-domain space movements** (for contrast) | `20260618000055_osn3_s1_space_schema.sql:56-63` | `double precision`, **CHECK `[-10000,10000]`** + finite | same | **YES (enforced)** | already canonical (the model to match) |
| **Client coord adapters** | `mapApi.ts` / `mapTypes.ts` pass x/y through unchanged; only `buildNormalizer` (dynamic) transforms at render | n/a | n/a | n/a | the dynamic transform is the thing to retire |

**Facts:** coordinates are **hardcoded seed** (no generator/RNG/world-build RPC); **axis is consistent**
(+y = up, Y-inverted in both transforms — no orientation mismatch); **only `main_ship_space_movements`
is domain-constrained**; nothing else has a CHECK. **No silent rescale/reinterpret is acceptable** — any
coordinate change is an explicit, reviewed data migration (PRES-1).

---

## B. Complete legacy-renderer dependency inventory

| File / function (file:line) | Rendered entity / behavior | Transform use | Direct move to `worldToViewBox`? | Prerequisite / risk |
|---|---|---|---|---|
| `GalaxyMap.tsx:78-86` `norm = useMemo(buildNormalizer(locations+base+movements))` | the dynamic normalizer itself | **dynamic bounds** | n/a (this is what's retired) | **canonical coords required first (PRES-1)** |
| `GalaxyMap.tsx:135` `homePt = norm(base)` | home/base diamond + label | `norm` | yes (mechanically) | base canonical (`(0,0)` ok) |
| `GalaxyMap.tsx:164-165` `a=norm(origin); b=norm(target)` | fleet movement lines | `norm` | yes | movement coords canonical |
| `GalaxyMap.tsx:205` `p = norm(loc)` | location markers | `norm` | yes | **location coords canonical (the blocker)** |
| `GalaxyMap.tsx:225` `norm={norm}` → `MainShipMarker` | ship legacy-state position | `norm` (via `markerViewBoxPoint` `legacy_dynamic` arm) | yes | ship legacy coords = base/location/movement → canonical |
| `MainShipMarker.tsx` `markerViewBoxPoint` `legacy_dynamic` → `norm` | ship legacy/named states | conditional | collapses to fixed once coords canonical | S6B4 helper already isolates this |
| `resolveMainShipMarker.ts:121/131/147/157/161` return `'legacy_dynamic'` | §D at_location, §E home, §F legacy | provenance tag | tag becomes vestigial post-unification | **STATE logic stays**; only the transform unifies (NOT a ship spatial_state migration) |
| `FleetMovementLine.tsx` | line/dot/ETA label | **pre-normalized input** (pure) | yes — parent supplies coords | none (presentation-only) |
| `LocationMarker.tsx` | location dot + label | **pre-normalized input** (pure) | yes | none |
| `GalaxyMap.tsx` camera (`view{k,tx,ty}`, `<g translate scale>`, `clampK`, `clampPan`, `toSvgUnits`, wheel/drag/reset) | pan/zoom | **viewBox-local only** | **INDEPENDENT of `norm`** | **no change needed** — swapping the world→viewBox fn doesn't touch camera math |
| `GalaxyMap.tsx` `viewBox="0 0 1000 1000"`, `preserveAspectRatio`, backdrop rect, `VIEW=1000` | SVG frame | fixed | unchanged | `VIEWBOX_SIZE===VIEW===1000` already shared with `worldToViewBox` |
| `MapPage.tsx`, `GalaxyMapScreen.tsx`, `LocationPanel.tsx`, `MainShipPreview.tsx` | list/detail views | **text only** (`Math.round(x), y`) | n/a | no transform dependency |
| `useGalaxyMapData.ts`, `mapApi.ts`, `mainshipApi.ts` | data fetch/poll | **pure passthrough** (no normalization) | n/a | data layer is coordinate-space-agnostic |
| **world wrapping** | — | **none found** | n/a | nothing to migrate |

**Final removal path for `buildNormalizer`** (delete only when ALL are done): replace `norm(...)` at the 4
GalaxyMap call sites (`:135, :164-165, :205`) + the `norm` prop (`:225`) with `worldToViewBox`; drop the
`legacy_dynamic` arm of `markerViewBoxPoint` (and collapse the `coordinateSpace` discriminant if it becomes
single-valued); remove `buildNormalizer` + `PAD` (keep `VIEW`/`VIEWBOX_SIZE`). `FleetMovementLine`,
`LocationMarker`, the camera, the SVG frame, the data layer, and list/detail views need **no** change.

---

## C. Unified fixed-rendering contract (the intended final frontend)

Every visual world entity flows: `WorldCoord → worldToViewBox() → existing camera <g> → SVG viewBox →
screen`. **No renderer relies on content-derived dynamic bounds.**

- **Shared world type:** reuse `WorldCoord` from `openSpaceTransform.ts` (`{x,y}` in canonical world units).
- **Fixed bounds policy:** the canonical domain is the single source of scale; `worldToViewBox`
  (scale `0.05`, `[-10000,10000]→[0,1000]`) is the only world→viewBox map. No per-content rescale.
- **Axis / Y-inversion ownership:** +y = north; Y-inversion lives **only** in `worldToViewBox`
  (`y = VIEWBOX_SIZE − (w.y − WORLD_MIN)·scale`) — exactly as today, so orientation is unchanged.
- **Camera pan/zoom order:** unchanged — `<g transform="translate(tx ty) scale(k)">` (scale-then-translate
  visually); camera operates in viewBox-local space, independent of the world→viewBox fn.
- **Label-anchor behavior:** unchanged — labels counter-scale by `1/k`, `showLabels` at `k≥0.9`; they
  consume viewBox coords from whichever transform produced the marker.
- **Movement-line / return-to-home endpoints:** endpoints produced by `worldToViewBox(origin/target)`;
  `FleetMovementLine` is unchanged (pure, viewBox-space input).
- **Entities outside the canonical domain:** **must not exist** in the unified world. PRES-1 guarantees
  all rendered entities are in-domain; (optional) DB CHECK constraints enforce it. A defensive client
  policy: an out-of-domain coord still maps linearly (no clamp) but would render off the `[0,1000]`
  viewBox — surfaced as a data error in PRES, never silently clamped.
- **Invalid/missing coordinates:** the resolver already returns `null` (no marker) for non-finite/missing
  coords; locations/base with missing coords are a data error, not a render-time guess.
- **Future open-space content:** already native to this layer (S6B markers use `worldToViewBox`).
- **Map wrapping:** **none today; remains removed** — no toroidal logic is added.
- **Mobile letterboxing / aspect ratio:** unchanged — `viewBox 0..1000` + `preserveAspectRatio
  "xMidYMid meet"` letterboxes the square world into any container (the S6B1 `viewBoxDisplayRect` models
  it); the fixed transform does not alter this.

---

## D. Safe rollout plan (slices — do NOT collapse into one conversion)

- **PRES-1 — Coordinate truth + data preparation (BACKEND DATA; no renderer switch).** Decide the
  canonical world layout and **migrate location/base coordinates into `[-10000,10000]` with a meaningful
  spread** (legacy movements inherit via the unchanged `send_*` RPCs). Optionally add finite+bounds CHECK
  constraints on `locations`/`bases`/`fleet_movements`. **No visual change** (the dynamic normalizer still
  fits whatever bounds exist, so the map looks the same before the renderer switch). **This is the
  prerequisite that makes every later slice a no-op-looking swap.**
- **PRES-2 — Named locations + base on the fixed transform.** Swap `norm→worldToViewBox` for location and
  base markers in `GalaxyMap.tsx`. (Optionally keep the dynamic renderer behind a dev-only diagnostic for
  controlled comparison — never a player-visible dual map.)
- **PRES-3 — Legacy ship travel, return travel, and movement lines on the fixed layer.** Swap the movement
  origin/target `norm` calls and the `MainShipMarker` legacy arm to `worldToViewBox` (or collapse the
  discriminant). Legacy gameplay routes untouched; only their **rendering** moves.
- **PRES-4 — Labels, mobile camera, pan/zoom, full map regression.** Verify every visible element is
  stable and usable at phone sizes, both orientations, min/max zoom, on resize.
- **PRES-5 — Dynamic renderer retirement.** Delete `buildNormalizer` + `PAD` + remaining dynamic
  consumers + the (now single-valued) `legacy_dynamic` path **only after** every supported path uses fixed
  coordinates and all acceptance evidence is green.

---

## E. Shadow / parallel validation (no player-visible dual map)
- **Pure fixed-vs-legacy comparison tests:** for deterministic known-coordinate fixtures, assert
  `worldToViewBox(p)` vs the legacy `buildNormalizer([...])(p)` over the **post-PRES-1 canonical bounds**
  agree (or document the intended difference). Pure, no DB.
- **Development-only dual-render diagnostic / overlay:** render the fixed layer faintly atop the legacy
  layer **behind `import.meta.env.DEV`**, compile-time eliminated from production (the S6B3 pattern) —
  for human comparison during PRES-2/3; **never** a player-visible mode.
- **Deterministic known-coordinate fixtures:** a small set of canonical world points → expected viewBox
  positions, asserted in pure tests.
- **Browser DOM checks / controlled manual visual proof:** a dev-mode screenshot for human sign-off
  (the live-Pages E2E path is out of bounds — it writes prod state). Manual, not a CI gate.
- **No player-visible dual-coordinate mode.**

---

## F. Mobile-first map requirements (acceptance)
Touch pan (drag), touch zoom (the current wheel/button model + pinch if added — but **no new gesture in
PRES**), small phone viewport (full-`h-[100dvh]` map), landscape↔portrait changes, SVG letterboxing
(`xMidYMid meet`), label overlap/readability (`showLabels` threshold + counter-scale), visual scale at min
(`k=0.4`) and max (`k=8`) zoom, camera stability on resize/orientation change (viewBox is size-invariant),
and **no required hover / keyboard / desktop-only interaction**. **Risk:** after PRES-1 the world spans the
full `[-10000,10000]` but only a few locations exist → at default zoom the content may appear sparse/tiny;
the **default camera framing** (initial `k`/`tx`/`ty`, or a "fit to content" *initial* view that does NOT
reintroduce dynamic per-frame bounds) is a mobile-usability decision to settle in PRES-4.

---

## G. Compatibility boundaries (preserved through ALL PRES work)
`mainship_send_enabled=TRUE`; `mainship_space_movement_enabled=FALSE`; the S6A command boundary stays
**dark**; **no** tap-to-select, target persistence, movement CTA, client command-RPC call, or coordinate
movement enablement; **no** implication that named locations are valid coordinate destinations until
separately approved. PRES is **rendering** unification only — gameplay routes and the dark command
boundary are untouched.

---

## H. Final retirement criteria (before deleting the dynamic renderer)
- every visible location/base/ship/movement endpoint has **verified canonical** world coordinates;
- named locations, base, legacy ship travel, returns, movement lines, and labels **all** use the fixed
  transform;
- all map camera + mobile behavior is proven (F);
- **no** `buildNormalizer()` / `legacy_dynamic` rendering consumer remains (B's removal path complete);
- `tsc -b` + `vite build`, map regression, `verify:osn:resolver`/`verify:osn:s6b`, and the relevant legacy
  movement verifiers are green;
- the transition is documented (DEV_LOG + GUIDE);
- **S6D remains blocked** until the unified renderer is fully implemented and approved.

---

## Final output (the eleven required items)

1. **Verified coordinate inventory:** §A — locations `[9,33]×[4,23]` (NOT canonical), base `(0,0)`, legacy
   movements inherit, only `main_ship_space_movements` is `[-10000,10000]`-constrained. Axis consistent.
2. **Dynamic-renderer dependency inventory:** §B — isolated to `GalaxyMap.tsx` (4 `norm` call sites + the
   `norm` prop) + the `MainShipMarker` `legacy_dynamic` arm; camera/SVG/data/list-views are independent;
   no wrapping. Removal path enumerated.
3. **Canonical coordinate contract:** §C — single `worldToViewBox` over fixed `[-10000,10000]`, Y-inversion
   owned there, camera unchanged, letterboxing preserved, no dynamic bounds.
4. **Recommended PRES slices:** §D — PRES-1 data → PRES-2 locations/base → PRES-3 legacy travel/lines →
   PRES-4 labels/mobile/regression → PRES-5 retire `buildNormalizer`.
5. **Data / migration risks:** the **coordinate-scale mismatch is the central risk** — a backend data
   migration (reseed/rescale locations+base into canonical coords) is REQUIRED before any renderer swap; a
   naive swap collapses the world to ~1px. Choices: rescale-existing (preserves relative layout) vs
   reseed-new (hand-placed world); optional CHECK constraints; legacy movements inherit automatically.
   **No silent rescale** — explicit, reviewed migration only.
6. **Mobile / camera risks:** §F — sparse/tiny content at default zoom after the domain widens → needs a
   sensible **initial** camera framing (one-time fit, not per-frame dynamic bounds); orientation/resize
   stability; label readability. Camera math itself is unaffected by the transform swap.
7. **Parallel-validation approach:** §E — pure fixed-vs-legacy comparison tests + dev-only (compile-time-
   removed) dual-render diagnostic + deterministic fixtures + manual dev screenshot; **no** player-visible
   dual map.
8. **Test & proof plan:** pure transform/comparison tests (extend `verify:osn:s6b`/`verify:osn:resolver`),
   a dev-only diagnostic guarded like S6B3 (+ dist-absence grep), `build`/typecheck, map regression
   (existing galaxy browser smoke stays read-only), and the legacy movement verifiers — all per slice; no
   new live-DB test for the rendering swaps. PRES-1's data migration uses the project's real-chain proof
   pattern (disposable Postgres) + a live read-only spot-check.
9. **Legacy-renderer deletion criteria:** §H.
10. **Decisions requiring approval:**
    - **(D1) Coordinate-data strategy [BLOCKER]:** rescale existing `[9,33]×[4,23]` into canonical
      coordinates vs reseed a new hand-placed world; and the **target spread/layout** within
      `[-10000,10000]`. This is backend data work (a migration) and the gate for everything else.
    - **(D2) Add CHECK constraints** to `locations`/`bases`/`fleet_movements` coords? (enforce canonical
      domain).
    - **(D3) Base placement:** keep all homes at `(0,0)` or distribute per-player? (affects multi-player
      future + camera framing).
    - **(D4) Discriminant fate:** collapse `coordinateSpace` to a single value after unification, or keep
      it for future relations.
    - **(D5) Initial camera framing** policy once the domain widens (fixed default vs one-time fit).
11. **Recommended first implementation slice:** **PRES-1 — Coordinate truth + data preparation**, decided
    by **D1** first. It establishes canonical coordinates for locations/base (legacy movements inherit),
    optionally adds CHECK constraints, and proves all entities are in-domain — **with no renderer switch
    and no visual change**. Everything visual (PRES-2+) is a safe, near-mechanical swap **only after**
    PRES-1 lands.

---

*Reconnaissance only — no code, no migration, no production change. Awaiting decisions (esp. D1) and an
explicit "begin PRES-1" before any implementation. S6C must not begin before this presentation decision is
chartered + approved.*

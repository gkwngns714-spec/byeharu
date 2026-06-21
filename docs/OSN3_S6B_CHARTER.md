# OSN-3 S6B — Fixed-Domain Coordinate Transform & Read-Only Preview
## Reconnaissance Charter

> **Status: RECONNAISSANCE ONLY.** No code, migration, flag, S6A change, commit, or push is produced
> by this charter. It ends with a proposed implementation slice plan that is **not** executed.
>
> **Goal.** Establish a single authoritative *frontend* coordinate-space layer matching the server's
> fixed world domain `x,y ∈ [-10000, 10000]`, exposing paired pure transforms `worldToMap` /
> `mapToWorld` that account for fixed bounds, Y-inversion, viewport, pan, and zoom — **still dark and
> read-only**, no player can command movement.
>
> **Standing constraints.** Both flags unchanged (`mainship_send_enabled=true`,
> `mainship_space_movement_enabled=false`). S6B may define/render the player's open-space ship position
> and a **non-interactive read-only preview target**, plus transforms + tests. S6B must **not** add:
> tap-to-select, click/tap command handling, selected-target persistence, a command CTA, request-id
> generation, public command-RPC calls, map-based movement, flag enablement, location docking, or any
> zone/pirate/mining/trade/captain work, and must **not** touch the private coordinate writer or arrival
> processor. `mapToWorld` may be designed + unit-tested in S6B but **must not be wired to any player
> input event** (S6C owns tap selection + confirmation).

---

## Amendment — Resolved decisions & coexistence guardrail (2026-06-22) — AUTHORITATIVE

> These supersede the "Decisions to confirm" at the bottom and any looser in-body wording.

1. **Fixed transform output space = `[0, 1000]`** (map-local), aligning directly with the existing SVG
   `viewBox="0 0 1000 1000"` — no `[0,1]` intermediate, no extra scale math; the fixed layer slots into
   the existing camera `<g>` unchanged.
2. **Marker provenance = an explicit discriminated field** `coordinateSpace: 'legacy_dynamic' |
   'open_space_fixed'` on the marker. **No ambiguous boolean** (`isFixed`, `space`, etc.). A
   marker-rendering call site must be unable to silently apply the wrong transform — the field is
   required and exhaustively switched.
3. **Read-only preview = development-only**, gated **solely** by `import.meta.env.DEV`. **No** URL query
   param, **no** localStorage, **no** backend flag, **no** RPC, **no** player input, **no** persisted
   selected target; `pointerEvents:'none'`; visibly distinct from the real ship, named locations, and a
   future S6C destination selection. **Production builds must not display it.**
4. **Pure-transform tolerance = `≤ 1e-6 world units` (absolute).** This applies to the pure
   mathematical fixed-domain round trips (`normToWorld(worldToNorm(P))`, etc.). **Do not** use
   `1e-6 × WORLD_SPAN` / `0.02` world units — too loose for double-precision linear transforms; it could
   hide an inversion or transform-order bug. A *separate, justified* tolerance may be defined **only**
   for a later browser/pixel-event test where measured pixel rounding genuinely requires it — it must
   not weaken this pure-transform invariant.

### Required coexistence guardrail (non-negotiable)
A **dynamic legacy location layer** and a **fixed open-space layer** are **not** automatically spatially
co-registered merely because they share the same SVG camera `<g>`. Therefore:
- S6B may use the fixed layer **only** as a development / read-only proof layer **while coordinate
  movement remains dark**.
- S6B **must not** imply that dynamic named locations are physically comparable landmarks for a
  fixed-domain in-space ship.
- **No S6D production enablement may proceed** until one of the following is explicitly **chartered,
  implemented, and proven**:
  1. named locations are rendered through a **verified fixed-domain transform**; or
  2. coordinate navigation uses a **clearly separate map mode/surface** where legacy dynamic markers are
     hidden or shown only as **non-spatial metadata**.

This is an **architectural guardrail, not an instruction to refactor named-location rendering during
S6B**. The presentation decision itself is owned by a **future pre-S6D slice** (see §F).

---

## A. Current map architecture — verified from source (frozen `888262b`)

All file paths under `C:\Users\gkwng\OneDrive\바탕 화면\byeharu\`.

### A.1 The world→screen pipeline (the heart of S6B)
`src/features/map/GalaxyMap.tsx` renders a plain SVG. The full chain today is:

```
world coords ──buildNormalizer (DYNAMIC)──▶ [0..1000] viewBox-local
            ──<g transform="translate(tx ty) scale(k)">──▶ camera-applied [0..1000]
            ──SVG viewBox="0 0 1000 1000" preserveAspectRatio="xMidYMid meet"──▶ pixels
```

- **`buildNormalizer(points)`** (`GalaxyMap.tsx:20-34`) — **DYNAMIC, content-derived**. `VIEW=1000`,
  `PAD=0.08`. Computes `minX/maxX/minY/maxY` over the supplied points, `span = max(maxX-minX,
  maxY-minY) || 1`, `inner = VIEW*(1-2*PAD) = 840`, `scale = inner/span`, centers via `offX/offY`, and
  **Y-flips**: `return p => ({ x: offX+(p.x-minX)*scale, y: VIEW - (offY+(p.y-minY)*scale) })`.
  - **Input space:** world. **Output space:** `[0..1000]` viewBox-local. **Source of truth:** the
    loaded point set. **Dynamic** (recomputed via `useMemo` over `[locations, base, movements]`,
    `GalaxyMap.tsx:77-85`). **Reuse verdict: must remain LEGACY-ONLY** — its bounds change with content,
    so it cannot be the authoritative fixed open-space layer.
- **`norm`** (`GalaxyMap.tsx:77-85`) — the memoized `buildNormalizer` over `locations + base +
  movement origin/target`. Every marker is positioned by `norm({world})` **inside** the camera `<g>`.
- **Camera state** `view = { k, tx, ty }` (`GalaxyMap.tsx:74`). Transform string
  `translate(${tx} ${ty}) scale(${k})` (`GalaxyMap.tsx:160`) → a normalized point `n` lands at
  `screenNorm = (tx + k·n.x, ty + k·n.y)` (**scale then translate**; pan applied *after* zoom).
  - **Zoom:** `clampK = min(8, max(0.4, k))` (`:36`); wheel factor `1.15`, buttons `1.25`; zoom is
    re-centered on the **viewBox centre (500,500)** via `tx' = cx-(cx-tx)·ratio` (`:112-130`).
  - **Pan:** `onPointerMove` adds `toSvgUnits(px)` deltas to `tx/ty`, then `clampPan` (`:100-111`).
    `toSvgUnits(dxPx) = dxPx*VIEW/rectWidth` (`:87-91`) — the **only** pixel-aware code.
  - **`clampPan(tx,ty,k)`** (`:43-48`) keeps content overlapping the viewBox (`content=k·VIEW`;
    bounds `[VIEW-content,0]` when zoomed in, `[0,VIEW-content]` when out). Camera-bounds only.
  - **Reset** `{k:1,tx:0,ty:0}` (`:132`).
- **Viewport / resize:** `<svg viewBox="0 0 1000 1000" preserveAspectRatio="xMidYMid meet"
  class="h-full w-full …">` (`:145-149`). The browser auto-letterboxes the 1000×1000 square into the
  container (uniform scale `min(W,H)/1000`, centered) — **no JS resize handler exists**. Static
  backdrop `<rect>` is drawn outside the transform (`:159`).

### A.2 Marker rendering pipeline
- **Locations:** `LocationMarker` (`LocationMarker.tsx`) — `cx/cy` already in `[0..1000]`, radius/label
  counter-scaled `r=7/k`, `vectorEffect="non-scaling-stroke"`. Rendered via `norm({loc.x,loc.y})`
  (`GalaxyMap.tsx:203-217`). Clickable (selection only — no command).
- **Home base:** cyan diamond via `homePt = norm({base.x,base.y})` (`GalaxyMap.tsx:134, 180-200`).
- **Movement lines:** `FleetMovementLine` from `norm(origin)`→`norm(target)` (`:162-177`).
- **Main-ship marker:** `MainShipMarker` (`MainShipMarker.tsx`) — last child of the transform `<g>`,
  `pointerEvents:none`, flag-gated by `mainshipSendEnabled` (`GalaxyMap.tsx:221-227`). It calls the
  pure resolver, then `p = norm({marker.x,marker.y})` (`MainShipMarker.tsx:34`), draws an upward
  chevron `r=7/k`, colour by state, and runs a **1 s tick only while `outbound|returning`**
  (`:22-31`). **So the ship currently shares the dynamic `norm` exactly.**

### A.3 The position resolver
`resolveMainShipMarker.ts` — the SINGLE pure read-only resolver. Returns `ShipMarker { entityId,
entityType:'main_ship', relation:'self', x, y (WORLD), state }` or `null`. States:
- `§B in_space` (`:61-68`) → ship-owned `space_x/space_y` (WORLD) — **open-space, dark on prod**.
- `§C in_transit` (`:71-91`) → interpolates the active **coordinate** movement origin→target (WORLD) —
  **open-space, dark on prod**. Returns `outbound`/`returning`.
- `§D at_location` (`:94-107`) → named-location WORLD coords (legacy-aligned).
- `§E home` (`:110-117`) → base WORLD coords.
- `§F legacy (spatial_state NULL)` (`:120-149`) → legacy interpolation/present/home (legacy-aligned).
- `§A/§G` → `null` (destroyed / unknown).
- **Provenance fact:** `§B/§C` are the open-space (coordinate-domain) states; `§D/§E/§F` are
  legacy/named states. The state enum **does not** by itself separate "coordinate outbound" (`§C`) from
  "legacy outbound" (`§F`) — both return `outbound`/`returning`. S6B needs a provenance signal (see C/F).

### A.4 Data / polling
`useGalaxyMapData.ts` polls ~4 s; `fetchActiveMainShipSpaceMovement` already feeds
`mainShipSpaceMovement`. `GalaxyMapScreen.tsx` is full-viewport (`h-[100dvh] flex flex-col`), map area
`flex-1`, `GalaxyMap` `h-full w-full`. No Zustand; React context/hook. **No coordinate writes anywhere.**

### A.5 Test + build harness to reuse
- `tests/resolveMainShipMarker.spec.ts` — **pure** Playwright `test`/`expect`, imports the module
  directly (no browser/page/DB). Run via `npm run verify:osn:resolver`
  (`= playwright test resolveMainShipMarker.spec.ts`), CI `verify-osn-resolver.yml` (dispatch-only,
  installs `@playwright/test` ad-hoc). **This is the exact vehicle for S6B's transform round-trip
  tests.** Browser visual specs exist too (`tests/galaxy.spec.ts`, `verify:galaxy:browser`).
- Build gate: `build.yml` (`tsc -b` + `vite build`, Node 22). Local toolchain unreliable (OneDrive) →
  **all verification in CI**.

### A.6 Transform inventory (each conversion, audited)
| Transform | In → Out | Source of truth | Dynamic/Fixed | S6B verdict |
|---|---|---|---|---|
| `buildNormalizer`/`norm` | world → `[0..1000]` | loaded points | **dynamic** | legacy-only; do NOT replace |
| camera `<g>` | `[0..1000]` → camera `[0..1000]` | `view{k,tx,ty}` | dynamic (user) | **reuse as-is** (shared by both layers) |
| `toSvgUnits` | px → viewBox units | SVG rect width | dynamic | reuse for pan; basis for px↔viewBox |
| SVG `preserveAspectRatio` | viewBox → px | container size | dynamic | reuse; basis for `mapToWorld` viewport step |
| resolver | state → WORLD | DB rows | n/a | unchanged; add provenance flag only |

---

## B. Transform contract (proposed)

**A two-layer design** — an inner *pure fixed* pair (authoritative, used to render markers inside the
existing camera `<g>`), and an outer *camera+viewport* pair (the full `worldToMap`/`mapToWorld` for
S6C's future tap, **designed + unit-tested in S6B but not wired**).

### B.1 Types
```ts
interface WorldCoord  { x: number; y: number }   // domain [-10000,10000]^2, +y = "north/up"
interface NormCoord   { x: number; y: number }   // viewBox-local [0..1000]^2 (pre-camera)
interface MapCoord    { x: number; y: number }   // screen pixels relative to the SVG element
interface Camera      { k: number; tx: number; ty: number }   // exactly GalaxyMap's view state
interface Viewport    { width: number; height: number }       // SVG client rect (px)
const WORLD_MIN = -10000, WORLD_MAX = 10000, WORLD_SPAN = 20000
const VIEW = 1000   // shared with GalaxyMap
```

### B.2 Inner pure FIXED pair (authoritative open-space layer)
```ts
worldToNorm(w: WorldCoord): NormCoord
normToWorld(n: NormCoord): WorldCoord
```
- `scale = VIEW / WORLD_SPAN = 0.05`.
- `worldToNorm`: `nx = (w.x - WORLD_MIN)*scale`; `ny = VIEW - (w.y - WORLD_MIN)*scale`  *(Y-inversion
  here, matching `buildNormalizer`)*. So `(-10000,-10000)→(0,1000)` bottom-left, `(10000,10000)→
  (1000,0)` top-right, `(0,0)→(500,500)` centre.
- `normToWorld`: `wx = nx/scale + WORLD_MIN`; `wy = (VIEW - ny)/scale + WORLD_MIN`.
- **Pure, fixed, no camera/viewport.** Exact linear inverse → `normToWorld(worldToNorm(P))` reproduces
  `P` to **`≤ 1e-6 world units` absolute** (Amendment §4). Maps the full square domain uniformly (no
  distortion; the square viewBox + `preserveAspectRatio` handle non-square containers).

### B.3 Outer camera + viewport pair (transform ORDER is explicit)
```ts
normToScreen(n: NormCoord, cam: Camera, vp: Viewport): MapCoord
screenToNorm(m: MapCoord, cam: Camera, vp: Viewport): NormCoord
worldToMap(w: WorldCoord, cam: Camera, vp: Viewport): MapCoord   // = normToScreen(worldToNorm(w))
mapToWorld(m: MapCoord, cam: Camera, vp: Viewport): WorldCoord   // = normToWorld(screenToNorm(m))
```
Order (world → pixel): **(1) `worldToNorm` (fixed, Y-invert) → (2) camera: scale THEN translate
(`tx + k·n`) → (3) viewBox→pixel via `preserveAspectRatio xMidYMid meet`**: `s = min(W,H)/VIEW`,
`offX = (W - VIEW·s)/2`, `offY = (H - VIEW·s)/2`, `px = offX + s·screenNorm.x`. Inverse reverses each
step (`screenNorm = (px-offX)/s`; `n = (screenNorm - t)/k`; `world = normToWorld(n)`).
- **Round-trip invariant:** the **pure** fixed round trips (`normToWorld(worldToNorm(P))` and
  `worldToNorm(normToWorld(N))`) must hold to **`≤ 1e-6 world units` absolute** (Amendment §4 — NOT
  `1e-6·WORLD_SPAN`). The **full** `mapToWorld(worldToMap(P, cam, vp), cam, vp) ≈ P` round trip holds for
  valid `P` and any in-range `cam`/`vp`; if a later browser/pixel-event test needs a looser bound due to
  measured pixel rounding, it is defined **separately and justified there** — it must not weaken the
  pure-transform invariant.
- **Rendering only needs the inner pair:** open-space markers render at `worldToNorm(world)` *inside*
  the existing `<g transform>`, so the camera/viewport are applied by SVG for free — no camera math at
  render time. The outer pair exists for S6C's screen↔world tap (tested now, unwired).

---

## C. Legacy coexistence boundary

**Recommended: Strategy 1 — two explicit layers, not co-registered in S6B.**
- The **new fixed layer** (`worldToNorm`) is authoritative **only** for **open-space** markers: the
  ship's `§B in_space` and `§C` coordinate-`in_transit` states, and the read-only preview (D).
- **`buildNormalizer` stays the SOLE owner** of all **legacy named-location visuals** — locations,
  base, legacy movement lines, **and** the ship's legacy/named states (`§D/§E/§F`). **Unchanged.**
- **Provenance routing (Amendment §2):** `resolveMainShipMarker` exposes an **explicit discriminated**
  field on `ShipMarker` — `coordinateSpace: 'legacy_dynamic' | 'open_space_fixed'` — set
  `'open_space_fixed'` only in `§B`/`§C`, `'legacy_dynamic'` in `§D/§E/§F`. `MainShipMarker`
  **exhaustively switches** on it: `'open_space_fixed' → worldToNorm`, `'legacy_dynamic' → norm`. **No
  ambiguous boolean** — a call site cannot silently pick the wrong transform (an unhandled variant is a
  type error). Adding the field is read-only and pure — it touches no backend and no legacy branch logic.
- **Markers ↔ transform mapping:** locations/base/legacy-lines/legacy-ship → `norm` (dynamic);
  open-space ship + preview → `worldToNorm` (fixed). Both render inside the same camera `<g>` and
  share pan/zoom.
- **Can a location exist in both layers?** No — named locations render only through the legacy
  layer in S6B; the fixed layer carries only open-space coordinate markers. (Unifying named locations
  onto the fixed world is a deliberately **deferred** larger map decision, not S6B.)
- **Z-index / layering:** keep current order (lines → base → locations → ship); render the read-only
  preview just under the ship marker, `pointerEvents:none`. No interaction layer added.
- **Camera coherence:** both layers consume the **same** `view{k,tx,ty}` `<g>`, so pan/zoom stay
  globally consistent; only the *content* of the fixed layer is dark on prod.
- **Honest divergence note (must be stated):** because coordinate movement is dark, open-space markers
  never appear on production in S6B, so the two layers are **never simultaneously visible** to players
  → **zero production visual change**, and the not-yet-co-registered legacy↔fixed spatial relationship
  has no S6B-visible effect. The charter records this as the explicit, accepted limit; full
  legacy/fixed co-registration is out of S6B scope.
- **Must be proven:** legacy named-location + base + legacy-movement rendering is **pixel-identical**
  before/after S6B (the legacy path uses an unchanged `buildNormalizer` and unchanged `§D/§E/§F`).

---

## D. Read-only preview model

"Read-only target preview" in S6B = a **non-persistent, non-commanding, non-tap** marker drawn at a
fixed WORLD coordinate through `worldToNorm`, to **prove the fixed layer renders correctly** — nothing
more. It is **not** generated by a tap, **not** stored, **not** sent to the server, **not** a movement
input.

- **Source (Amendment §3 — resolved):** a **development-only, non-persistent local fixture** — a
  constant WORLD coordinate rendered **solely** behind `import.meta.env.DEV`. **Explicitly NOT:** no URL
  query param, no localStorage, no backend flag, no RPC, no player input, no persisted selected target.
  `import.meta.env.DEV` is statically false in `vite build`, so **production builds never display it**
  (and a dead-code-eliminated branch keeps it out of the player bundle).
- **Visual distinction (must differ from all of):** the **real ship** (filled chevron, state colours)
  → preview = a **hollow ring + crosshair** in a neutral/dev colour (e.g. slate/grey), clearly "not a
  real object"; from **named locations** (filled dots) → different shape; from a **future S6C
  player-selected destination** (which will be interactive + confirmable) → the S6B preview is
  explicitly inert/dev-only, with a `data-testid="s6b-readonly-preview"` and (dev-gated) "preview"
  label, never a CTA.
- It shares `worldToNorm` + the camera `<g>` with the open-space ship, so it pans/zooms identically —
  which is exactly the camera-coherence proof (E.6).

---

## E. Test matrix

**Pure transform unit tests** (new `tests/openSpaceTransform.spec.ts`, mirroring
`resolveMainShipMarker.spec.ts`; run via a new `verify:osn:s6b` script + workflow):

1. **Fixed-domain corners** (`worldToNorm`): `(-10000,-10000)→(0,1000)`, `(-10000,10000)→(0,0)`,
   `(10000,-10000)→(1000,1000)`, `(10000,10000)→(1000,0)`.
2. **Centre:** `(0,0)→(500,500)`.
3. **Near-edge / off-by-one:** `9999, 10000, -9999, -10000` on each axis map to expected norm values;
   a chosen epsilon (e.g. `±1e-9`) stays within tolerance.
4. **Round-trips:** pure — `normToWorld(worldToNorm(w)) ≈ w` and `worldToNorm(normToWorld(n)) ≈ n` to
   **`≤ 1e-6 world units` absolute** (Amendment §4); and the full
   `mapToWorld(worldToMap(w,cam,vp),cam,vp) ≈ w` across **multiple viewport sizes** (square, landscape,
   portrait), **multiple pan positions** (incl. clamped extremes), **multiple zoom levels**
   (`0.4, 1, 2, 8`) — the pure layers within `1e-6`; any **pixel-event** bound (S6C territory) is
   defined and justified separately, never weakening the pure invariant.
5. **Y-orientation:** increasing world `y` strictly **decreases** norm `y` (renders upward),
   consistently across the domain.
6. **Camera correctness (visual / browser spec):** ship + preview move **together** under pan/zoom (no
   relative drift); no drift between `in_space` and coordinate-`in_transit` rendering; **no camera jump
   on map resize** (viewBox/preserveAspectRatio is size-invariant).
7. **Regressions:** legacy named locations/base/lines **pixel-stable** before/after; existing
   `resolveMainShipMarker` legacy interpolation unchanged (`verify:osn:resolver` stays green); **no**
   change to command UI / RPC behavior; **flag false → no coordinate command affordance** (S6B adds
   none); `tsc -b` + `vite build` green.

---

## F. Implementation slicing recommendation (NOT executed)

- **S6B1 — pure fixed-domain transform module + unit tests.** New
  `src/features/map/openSpaceTransform.ts` (`worldToNorm/normToWorld` + `worldToMap/mapToWorld/
  normToScreen/screenToNorm` with `Camera`/`Viewport` types). New `tests/openSpaceTransform.spec.ts`
  (E.1–E.5). New `package.json` script `verify:osn:s6b` + `verify-osn-s6b.yml` (mirror
  `verify-osn-resolver.yml`). **No rendering wiring.** `mapToWorld` exists + tested, **unwired**.
- **S6B2 — render the ship's open-space states through the fixed layer (still dark).** Add the
  discriminated `coordinateSpace: 'legacy_dynamic' | 'open_space_fixed'` field to `ShipMarker` (set
  `'open_space_fixed'` in `§B/§C` only); `MainShipMarker` exhaustively switches it to choose
  `worldToNorm` vs `norm`. Legacy states + `buildNormalizer` untouched. No prod visual change
  (open-space states dark).
- **S6B3 — non-interactive read-only preview proof.** Dev-gated constant-world preview marker
  (distinct hollow-ring glyph, `pointerEvents:none`, `data-testid`), rendered via `worldToNorm`; a
  Playwright visual spec asserts ship+preview co-move under pan/zoom and legacy markers are stable.
- **S6B4 — visual / regression acceptance + closure.** Run `verify:osn:s6b`, `verify:osn:resolver`,
  `build`, the visual spec; confirm flags unchanged, legacy pixel-stable; docs closure (DEV_LOG +
  GUIDE) **only on green**.
- **S6B-PRES (future pre-S6D slice; NOT S6B, NOT chartered yet) — owns the fixed-space ↔ named-location
  presentation decision.** Per the coexistence guardrail, **S6D production enablement is blocked** until
  this slice charters, implements, and proves **either** (1) named locations rendered through a verified
  fixed-domain transform, **or** (2) a separate coordinate map mode/surface where legacy dynamic markers
  are hidden or shown only as non-spatial metadata. S6B deliberately does **not** make this decision; it
  only proves the fixed layer in isolation while coordinate movement stays dark.

**Files likely to change:** `src/features/map/openSpaceTransform.ts` (new), `tests/openSpaceTransform.spec.ts`
(new), `.github/workflows/verify-osn-s6b.yml` (new), `package.json` (one script), `MainShipMarker.tsx`
(provenance-based transform choice + preview), `resolveMainShipMarker.ts` (add a pure provenance field),
possibly `GalaxyMap.tsx` (pass dev-preview prop). **Files that must NOT change:** `buildNormalizer`/the
legacy `norm` logic, the legacy `§D/§E/§F` resolver branches, any `supabase/migrations/**`, any RPC,
all S6A artifacts (migration 0060, the wrapper, the flag tool, the proofs), the command UI / RPC layer.
**Backend work required: none.** **Build/test proof:** `tsc -b` + `vite build`, `verify:osn:s6b`,
`verify:osn:resolver`, a browser visual spec; no migration/deploy. **Deferred entirely to S6C:**
tap-to-select, wiring `mapToWorld` to pointer events, selected-target persistence, the command CTA,
request-id generation, and any public command-RPC call.

---

### Decisions — RESOLVED (2026-06-22; see "Amendment" at top)
1. Transform output space = **`[0, 1000]`** viewBox-local — **resolved.**
2. Provenance = discriminated **`coordinateSpace: 'legacy_dynamic' | 'open_space_fixed'`** (no boolean) —
   **resolved.**
3. Preview gating = **`import.meta.env.DEV` only** (no query param / localStorage / flag / RPC / input /
   persistence) — **resolved.**
4. Coexistence = **Strategy 1** + the **non-negotiable guardrail** (no automatic spatial co-registration;
   S6D blocked until the S6B-PRES presentation slice lands) — **resolved.**
5. Pure-transform tolerance = **`≤ 1e-6 world units` absolute** (NOT `1e-6·WORLD_SPAN`); any pixel-event
   tolerance defined separately — **resolved.**

*Reconnaissance only — no code. S6B1 is scoped and ready, awaiting an explicit "begin S6B1" instruction.*

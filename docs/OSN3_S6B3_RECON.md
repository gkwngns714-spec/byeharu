# OSN-3 S6B3 — Development-Only Fixed-Space Preview & Visual Camera Proof
## Reconnaissance Charter (local-only)

> **Status: RECONNAISSANCE ONLY.** No code, commit, push, flag, migration, RPC, command path, or S6A
> change; ends with a proposed implementation boundary that is **not** executed. Baseline frozen:
> `main == origin/main` at `f7974ac`; S6A deployed + dark; `mainship_send_enabled=true`,
> `mainship_space_movement_enabled=false`; S6B1 fixed transform merged; S6B2 provenance routing merged;
> production renders only legacy-dynamic ship states.

## Goal
The smallest safe **development-only** proof that the fixed coordinate layer (1) renders a
**non-interactive** fixed-world preview marker; (2) **co-moves** correctly with an open-space ship marker
under the existing camera pan/zoom; (3) is **absent from production builds**; (4) creates **no** player
input, selection state, persistence, RPC traffic, or movement-command behavior. This is a **visual proof
layer** for the transform and future S6C work — **not** a gameplay feature.

## Hard restrictions (carried verbatim)
S6B3 must **not** add: tap/click/pointer selection; user-derived target state; request IDs; a command
CTA; command-RPC calls; flag enablement; localStorage / URL state / backend storage / DB writes;
named-location coordinate conversion; any UI implying named locations are physically co-registered with
the fixed preview; any change to the server, migration chain, S6A boundary, or the open-space writer /
arrival processor. The preview must be: gated **solely** by `import.meta.env.DEV`; **absent** from
production builds; non-persistent; `pointerEvents:'none'`; visually distinct from the real ship and
location markers; **not** generated from a player tap; **not** passed to any command code.

---

## A. Exact render insertion point (post-S6B2, frozen `f7974ac`)

`src/features/map/GalaxyMap.tsx` renders one transform group. **Document order = SVG paint order
(bottom → top):**
```
<svg viewBox="0 0 1000 1000" preserveAspectRatio="xMidYMid meet" …>   (pan/zoom/wheel handlers, onClick deselect)
  <rect … fill="#070b14" pointerEvents="none"/>                       (static backdrop, OUTSIDE the camera <g>)
  <g transform="translate(tx ty) scale(k)">                          (the camera group)
     {movements.map(FleetMovementLine)}        (:162-177)   ── bottom
     {homePt && home-base diamond + label}     (:180-200)
     {locations.map(LocationMarker)}           (:203-217)
     {mainshipSendEnabled && <MainShipMarker/>}(:221-227)   ── current top (the real ship; pointerEvents:none)
  </g>
  <div … bottom-left status text>                                    (HTML overlay, outside the SVG)
</svg>
```

**Insertion point:** a new **dev-gated** preview as the **last child inside the camera `<g>`**, *after*
`MainShipMarker`:
```
{import.meta.env.DEV && <DevFixedSpacePreview k={view.k} />}
```
- **Why inside `<g>`:** so the existing `translate(tx ty) scale(k)` applies pan/zoom to the preview for
  free — the same camera that moves the real ship — which is the whole co-movement proof.
- **Why `worldToViewBox()` before `<g>`:** the preview holds a constant WORLD coordinate; `worldToViewBox`
  maps it to viewBox-local `[0..1000]` (the space the `<g>` consumes), exactly as the open-space ship
  marker does in S6B2 (`MainShipMarker`'s `open_space_fixed` arm). Identical transform + identical camera
  ⇒ identical pan/zoom response ⇒ co-movement **by construction**.
- **Dedicated component (recommended):** `DevFixedSpacePreview.tsx` keeps the GalaxyMap edit to a single
  dev-gated line and isolates all dev-only code for tree-shaking (see B).
- **Non-disturbance:** the preview is `pointerEvents:'none'` (cannot intercept the ship or map drag/zoom —
  pan is handled on the `<svg>`, selection on `LocationMarker`/`onClick`); it adds no label to the label
  layer; it touches no movement-line/marker/ordering code; it reads no data (a constant fixture), so
  polling/`useGalaxyMapData` are untouched.

**Explicit z-order after S6B3 (bottom → top):** movement lines → home base → **legacy location markers**
→ real main ship → **dev preview marker** → (HTML status overlay, outside SVG). The preview sits on top
visually but, being at a *distinct* fixed-world coordinate (C) and `pointerEvents:'none'`, it **neither
obscures nor intercepts** the real ship or map gestures. *(Alternative placement — directly **below**
`MainShipMarker` so the ship always wins any overlap — is noted as a fallback if review prefers the real
ship strictly on top; the distinct coordinate makes overlap a non-issue either way.)*

---

## B. Development-only gating proof

- **Gate location:** the JSX render site only — `{import.meta.env.DEV && <DevFixedSpacePreview …/>}` in
  `GalaxyMap.tsx`. No runtime feature flag, no URL flag, no localStorage, no server setting is involved
  (none is read or written).
- **Why it is removed from production:** Vite statically replaces `import.meta.env.DEV` with the literal
  `false` in `vite build` (production mode). Rollup then dead-code-eliminates `{false && <…/>}`. If
  `DevFixedSpacePreview` is **side-effect-free** (a pure component module), its now-unreferenced code is
  tree-shaken from the production bundle.
- **Structural production-absence proof (required — not "we just won't show it"):** add a CI step that
  runs `vite build`, then **greps `dist/**` for a unique sentinel** that exists *only* in the preview
  path (e.g. the component's `data-testid="s6b3-dev-preview"` string and/or the named fixture constant)
  and **asserts it is absent**. A present sentinel fails the gate. This proves removal structurally from
  the actual emitted bundle, independent of any "it didn't render" claim.
- Belt-and-suspenders option: reference the component via `import.meta.env.DEV ? <Dev/> : null` only, and
  keep the module import side-effect-free, so even the import binding is shakeable. The grep is the
  authoritative proof regardless.

---

## C. Preview coordinate contract

- **Fixture (proposed):** `DEV_PREVIEW_WORLD = { x: 8000, y: -8000 }` — a single constant in the
  map-development layer (inside `DevFixedSpacePreview.tsx`), **not** an exported gameplay target and
  **not** a precursor to any S6C selected-target state.
- **Why chosen:** it is **near a corner** of the fixed domain (open, empty space), deliberately **away
  from** the home base (auto-provisioned at world `(0,0)`) and away from the clustered named-location
  region, so it visibly reads as "a point in open space," not a landmark. It is intentionally **not** any
  named-location coordinate.
- **Why it cannot falsely suggest a named-location relationship:** named locations render through the
  **dynamic** `buildNormalizer` layer; the preview renders through the **fixed** `worldToViewBox` layer.
  They are **not co-registered** (the S6B premise), so the fixture is in a different coordinate
  interpretation entirely; an edge coordinate + distinct glyph (D) + no distance/label UI keeps that
  clear on screen.
- **Expected viewBox after `worldToViewBox({8000,-8000})`:** `x = (8000+10000)·0.05 = 900`;
  `y = 1000 − (−8000+10000)·0.05 = 1000 − 100 = 900` → **`(900, 900)`** (lower-right region, pre-camera).
  *(Final value subject to confirming the constant during implementation; the formula is fixed.)*

---

## D. Visual distinction & accessibility

Intentionally minimal — it proves position + camera movement, not product art.
- **Shape:** a **hollow ring + crosshair** (open circle with a small plus through it) — structurally
  different from the real ship's **filled upward chevron** and from **filled location dots**.
- **Size:** small, counter-scaled `r ≈ 7/k` (same on-screen-constant convention as other markers), no
  larger than the ship marker.
- **Stroke/fill:** **no fill** (hollow) + a thin stroke with `vectorEffect="non-scaling-stroke"`; a
  neutral **dev/grey** colour (e.g. slate `#94a3b8`), distinct from ship state colours (emerald/amber/
  sky) and location type colours.
- **Opacity:** modest (e.g. `0.7`) to read clearly as a non-solid proof artifact.
- **Label policy:** none (or a single dev-only tiny "preview" tag); never copy implying distance/relation
  to any named location.
- **pointer-events:** `'none'`.
- **Accessibility:** it is a **dev-only, decorative** SVG artifact, not player content → mark
  `aria-hidden="true"` (role presentation) so assistive tech ignores it; carry `data-testid="s6b3-dev-preview"`
  for the smoke/absence checks.
- **Distinction summary:** vs **real ship** (filled chevron, coloured) → hollow grey ring; vs **named
  location** (filled dot, coloured + clickable) → hollow + `pointerEvents:none`; vs **future S6C selected
  destination** (interactive, confirmable) → inert dev-only; vs **debug artifacts** → it is the *only*
  preview marker, tagged and dev-gated.

---

## E. Visual proof plan

1. **Preview appears only in development** — dev-mode render shows the `data-testid="s6b3-dev-preview"`
   marker.
2. **Production build does not render it** — **structural**: `vite build` + grep `dist/**` for the
   sentinel → **absent** (B). This is the authoritative gate (CI, deterministic). *(Optionally, the
   existing live-Pages browser test — `verify:galaxy:browser` runs against the production Pages site —
   can additionally assert the testid is absent on prod.)*
3. **Preview and fixed-space ship share the same world→viewBox transform** — **by construction**: both
   call `worldToViewBox` (S6B1) inside the same camera `<g>`; the S6B1 unit tests already prove that
   transform + camera. No new math.
4. **Preview and fixed-space ship pan/zoom together** — a **dev-mode browser smoke** (Playwright) drives
   the existing pan/zoom and asserts the preview marker translates/scales with the camera (its screen
   position tracks `worldToViewBox(fixture)` under the live `view{k,tx,ty}`). Because the open-space ship
   uses the identical transform/group, co-movement with the ship is the logical corollary — proving it on
   the preview alone avoids seeding a forced `in_space` ship (out of S6B3 scope). *(If review wants a
   side-by-side ship+preview shot, a temporary dev-only in_space ship fixture could be used for a manual
   screenshot, but that is explicitly optional and not part of the minimal gate.)*
5. **No drift under pan/zoom** — the smoke asserts the preview's expected vs actual screen position stay
   equal across several `k`/pan states (behavioral, not pixel-snapshot).
6. **Legacy named locations unchanged** — the existing galaxy browser smoke + `verify:osn:resolver`
   remain green; locations still render through `buildNormalizer` untouched.
7. **No pointer interception / pan interference** — assert the preview node has `pointer-events:none`,
   and map drag/zoom + location selection still work with the preview present.
8. **No production behavior change** — coordinate movement stays dark; on prod the preview is absent (2)
   and the ship stays `legacy_dynamic` (S6B2), so nothing visible changes.

**Vehicle choice:** primary gate = **dev-only local fixture + structural production-absence grep**
(deterministic, no flakiness); secondary = a **small dev-mode Playwright smoke** for presence +
co-movement + pointer-events. **No brittle pixel-perfect snapshot** — the repo's browser tests are
behavioral (no stable snapshot vehicle exists), so none is introduced; assertions are on testid presence/
absence and computed-position equality.

---

## F. S6B3 implementation boundary (NOT executed)

- **Files likely to change:**
  - **New** `src/features/map/DevFixedSpacePreview.tsx` — the dev-only preview component: the
    `DEV_PREVIEW_WORLD` constant, `worldToViewBox` usage, the hollow-ring glyph, `pointerEvents:'none'`,
    `aria-hidden`, `data-testid`. Side-effect-free for tree-shaking.
  - `src/features/map/GalaxyMap.tsx` — **one** dev-gated line inside the camera `<g>`, after
    `MainShipMarker`: `{import.meta.env.DEV && <DevFixedSpacePreview k={view.k} />}`. No other edit; no
    change to `buildNormalizer`/`norm`, pan/zoom, ordering, or data.
  - **New** browser smoke spec (e.g. `tests/s6b3DevPreview.spec.ts`) for E.1/E.4/E.5/E.7 — dev-mode.
  - Possibly **new** CI workflow `verify-s6b3-prod-absence.yml` (build + grep `dist` for the sentinel)
    and/or a dev-mode browser job; `package.json` may gain a `verify:s6b3` script. *(Prefer a dedicated
    new workflow over editing `build.yml`.)*
- **Files that must NOT change:** `resolveMainShipMarker.ts`, `MainShipMarker.tsx` (S6B2 — final),
  `openSpaceTransform.ts` (S6B1 — frozen, reused), the `buildNormalizer`/`norm` logic, `LocationMarker.tsx`,
  `FleetMovementLine.tsx`, `useGalaxyMapData.ts`, `mainshipApi.ts`, any `supabase/migrations/**`, any RPC,
  the open-space writer/arrival processor, all S6A artifacts, all flags.
- **Dedicated component?** **Yes** — `DevFixedSpacePreview.tsx` (isolates dev-only code + keeps GalaxyMap
  to one line).
- **Where tests belong:** the **production-absence** proof is a build+grep CI step (not a unit test); the
  **dev presence / co-move / pointer-events** proof is a **new dev-mode browser smoke**. The pure
  transform correctness is already covered by S6B1's `verify:osn:s6b`; provenance by S6B2's
  `verify:osn:resolver` — **neither is modified**.
- **Dedicated workflow?** Recommended: a small new workflow for the production-absence grep (deterministic,
  CI-only); the dev browser smoke can be a new job/spec. Avoid editing `build.yml`/`verify-osn-resolver`.
- **Proof required before merge:** `tsc -b` + `vite build` green; **production-absence grep green**
  (sentinel absent from `dist`); dev browser smoke green (preview present in dev, pointer-events none,
  co-moves, no drift, locations stable); `verify:osn:s6b` + `verify:osn:resolver` still green; flags
  unchanged.
- **Acceptance criteria:** preview renders only in dev; **absent from the production bundle (grep-proven)**;
  uses the same `worldToViewBox` + camera `<g>` as the open-space ship (co-move by construction +
  smoke-confirmed); `pointerEvents:'none'`, visually distinct, no label/copy implying location relation;
  zero production behavior change; no input/selection/persistence/RPC/flag added.
- **Deliberate exclusions:** no tap/`mapToWorld` wiring (S6C), no command/CTA/request-id/RPC (S6C/S6D),
  no flag enablement (S6D), no forced in_space ship fixture in the gate (optional manual only), no
  named-location co-registration, no `buildNormalizer`/data/polling change, no backend change.

---

### Guardrail restated
**S6B3 does NOT resolve the fixed-space ↔ named-location presentation problem.** It is a dark,
dev-only visual proof of the transform layer. **`S6B-PRES` remains mandatory** — named locations must be
rendered through a verified fixed-domain transform, **or** coordinate navigation must use a separate map
mode/surface (legacy markers hidden / non-spatial), **before any S6D production enablement**.

*Reconnaissance only — no code. Awaiting an explicit "begin S6B3" instruction.*

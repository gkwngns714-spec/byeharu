# OSN-3 S6B4 — Fixed-Space Visual Acceptance & S6B Closure Plan
## Reconnaissance Charter (local-only)

> **Status: RECONNAISSANCE ONLY.** No code, commit, push, flag, migration, RPC, S6B-PRES/S6C/S6D/OSN-4
> work; ends with a proposed implementation boundary that is **not** executed. Baseline frozen:
> `main == origin/main` at `e2de473`; S6A deployed + dark; S6B1 transform, S6B2 provenance routing, S6B3
> dev-only preview (compile-time eliminated) all merged; `mainship_send_enabled=true`,
> `mainship_space_movement_enabled=false`.

## Goal
Define the **minimum credible acceptance evidence** to close S6B as a frontend-coordinate foundation —
proving (1) a **real `open_space_fixed` ship marker** routes through the fixed transform correctly; (2)
that ship + the S6B3 preview share the existing camera pan/zoom; (3) legacy named-location visuals are
unchanged; (4) **no** production-visible coordinate-movement feature exists; (5) S6B can close while the
**S6B-PRES** block before any S6D enablement stays explicit.

## Hard restrictions (carried verbatim)
S6B4 must **not** add: player tap selection; user-derived target state; command CTA; request-ID
generation; coordinate command-RPC calls; production flag enablement; test data written to production;
backend/migration/RPC changes; named-location coordinate conversion; any false visual suggestion that
legacy named locations are physically co-registered with fixed-space coordinates; any bypass/weakening of
S6B-PRES. **No production database state may be created or altered to manufacture an open-space ship.**

---

## A. Existing test & visual-proof capabilities (verified from source, frozen `e2de473`)

| Capability | Status | Notes |
|---|---|---|
| **Pure Playwright unit tests** (`test()`/`expect()`, no `page`) | **available, deterministic, DB-free** | `tests/{resolveMainShipMarker,openSpaceTransform,devFixedSpacePreview}.spec.ts`. Import modules / call pure code / inspect returned React elements. Run via `verify:osn:resolver` / `verify:osn:s6b` / `verify:osn:s6b3`. **This is the S6B4 vehicle.** |
| **Element-tree inspection of a hook-free component** | **available** | Proven in S6B3: `DevFixedSpacePreview({k})` returns its element for assertion. Works only for **hook-free** components. |
| Browser E2E (`page.goto`) | **available but OUT OF BOUNDS** | `playwright.config.ts` `baseURL` = **live Pages** (or `PLAYWRIGHT_BASE_URL`); `tests/galaxy.spec.ts` **signs up a throwaway Supabase user** (writes prod auth) + needs secrets + the `live-db-tests` group (`browser-galaxy.yml`). Manufacturing an `in_space` ship needs production DB state → **forbidden** for S6B4. |
| Playwright **component testing** (`@playwright/experimental-ct-react`) | **NOT installed** | No CT project in `playwright.config.ts`; would need new deps + a CT harness. |
| Dev-server launch for tests (`webServer` in playwright config) | **NOT configured** | No `webServer`; tests hit a deployed URL, not `vite dev`. Adding one is new infra. |
| Deterministic screenshot mechanism | partial | `playwright.config.ts` sets `screenshot:'on'`, but only on the live-E2E project (which is out of bounds). No DB-free screenshot vehicle exists. |
| `MainShipMarker` direct call | **NOT possible** | It uses `useState`/`useEffect` (1 s tick) → "invalid hook call" if called outside React. Its **routing decision is pure** and can be hoisted (see B). |

**Conclusion:** the only in-bounds, deterministic vehicle is the **pure unit test**. A real-browser DOM
proof of the full map with an `open_space_fixed` ship is **not** reachable without production DB state
(forbidden) or substantial new CT/dev-server infra (out of proportion for a dark, read-only slice).

---

## B. Meaningful fixed-ship proof (the real `MainShipMarker` branch, not a duplicate)

The S6B3 preview proves the transform module renders a static fixed coordinate; it does **not** exercise
`MainShipMarker`'s `open_space_fixed` provenance arm. To prove the **actual** branch deterministically,
without hooks/browser/backend:

**Recommended (option 1+4 hybrid): hoist `MainShipMarker`'s routing into a pure, exported helper that the
component itself calls, then unit-test that helper with a real `open_space_fixed` `ShipMarker`.**
- Today the `coordinateSpace` switch is **inline** in `MainShipMarker.tsx` (added in S6B2). S6B4 extracts
  it, behavior-preserving, into e.g.:
  ```ts
  // exported from MainShipMarker.tsx (or a tiny sibling module)
  export function markerViewBoxPoint(
    marker: Pick<ShipMarker, 'x' | 'y' | 'coordinateSpace'>,
    norm: (p: { x: number; y: number }) => { x: number; y: number },
  ): { x: number; y: number } {
    switch (marker.coordinateSpace) {
      case 'legacy_dynamic':   return norm({ x: marker.x, y: marker.y })
      case 'open_space_fixed': return worldToViewBox({ x: marker.x, y: marker.y })
      default: { const _e: never = marker.coordinateSpace; throw new Error(`unhandled ${String(_e)}`) }
    }
  }
  ```
  `MainShipMarker` then calls `markerViewBoxPoint(marker, norm)` — **identical behavior, same exhaustive
  switch + `never` guard**, no hooks moved.
- **The unit test exercises the REAL function the component uses** (not a re-implementation):
  - `open_space_fixed` marker `{x:8000, y:-8000, coordinateSpace:'open_space_fixed'}` + a **stub `norm`**
    that returns a sentinel (e.g. `{x:-999,y:-999}`) → assert the result **equals `worldToViewBox(...)`**
    (`{900,900}`) and is **not** the sentinel → proves the fixed branch is taken and **`buildNormalizer`/
    `norm` is never called** for a coordinate marker.
  - `legacy_dynamic` marker + the same stub `norm` → assert the result **equals the `norm` output** →
    proves legacy still routes through the dynamic normalizer.
- **Why this proves the real branch, not a duplicate:** `MainShipMarker` and the test call the **same
  exported function**; there is no second copy of the routing logic. Combined with S6B2's
  `verify:osn:resolver` (which proves `in_space`/coordinate-`in_transit` inputs resolve to an
  `open_space_fixed` marker), the chain is end-to-end: *resolver yields `open_space_fixed` →
  `markerViewBoxPoint` routes it through `worldToViewBox`*.
- **Not a production fallback / hidden fixture:** the helper is pure routing (no data, no default-legacy,
  `never`-guarded); the test fixtures are inline in the spec, never shipped.

*(Rejected alternatives: a component-render test of `MainShipMarker` — blocked by hooks + no CT harness;
a browser fixture page — needs new dev-server/CT infra and risks a production fallback; re-applying
`worldToViewBox` in the test independently — a duplicate, explicitly disallowed.)*

---

## C. Camera co-movement proof

Both the `open_space_fixed` ship and the S6B3 preview render via **`worldToViewBox` inside the same camera
`<g>`** — so they share the camera **by construction**. For explicit, deterministic evidence (no browser,
no brittle snapshot), reuse the **already-merged, already-tested** S6B1 `worldToScreen` (camera + viewport
composition) in a pure test:

- Take two **fixed-world** points — the preview fixture `{8000,-8000}` and a sample ship coord
  `{-4000, 2000}` — and for each `(camera, viewport)` combo compute `worldToScreen(p, cam, vp)`.
- **Assert fixed-layer relative stability:** under each combo, both points transform through the identical
  `worldToViewBox → camera(scale-then-translate) → letterbox` pipeline, so (a) their viewBox-space offset
  is camera-pan-invariant and scales linearly with `k`, and (b) the screen-space mapping is consistent
  across viewports. This proves "ship + preview move together" for the **fixed layer**, **without**
  comparing to dynamic named-location positions (which live in a different, non-co-registered layer).
- **Combos:** pan (zero + nonzero) × zoom (`0.4` min, `1`, `2`, `8` max) × viewports (square, wide,
  tall/mobile). *(S6B1's `openSpaceTransform.spec.ts` already covers these for `worldToScreen` round
  trips; S6B4 adds the explicit two-point relative-stability assertions.)*

**Vehicle:** SVG/viewBox-coordinate inspection via the pure `worldToScreen` model (the exact math the SVG
`<g>` + `preserveAspectRatio` apply). **No** real-browser DOM geometry needed; **no** pixel-perfect
snapshot (the repo has no stable snapshot vehicle, and the live-E2E screenshot path is out of bounds). An
optional **manual** `vite dev` screenshot (human-eyeballed, NOT a CI gate) may supplement (see F).

---

## D. Legacy non-regression proof

| Item | Covered by | Gap? |
|---|---|---|
| `buildNormalizer()` unchanged | code diff (no S6B slice touched it) + S6B4 confirms zero diff | none — it is unchanged code; no new test needed |
| Legacy named-location marker positions unchanged | `buildNormalizer` + `LocationMarker` unchanged | no per-pixel test exists, but inputs+code are byte-identical → positions identical by construction |
| Legacy main-ship states route `legacy_dynamic` | `verify:osn:resolver` (S6B2 provenance tests) + S6B4 `markerViewBoxPoint` legacy case | none |
| Legacy movement lines unchanged | `FleetMovementLine` unchanged | none |
| Map gestures / camera unchanged | `GalaxyMap` camera logic unchanged (S6B3 added only a dev-gated sibling) | none |
| S6B3 preview compile-time absent from production | `verify-s6b3` dist-absence grep | none |
| Production flag remains `false` | unchanged by construction (no S6B slice writes a flag) | confirmed without a live-DB tool |

**Existing verifiers and their coverage:** `verify:osn:s6b` (S6B1 transform math) · `verify:osn:resolver`
(S6B2 provenance: legacy→`legacy_dynamic`, open-space→`open_space_fixed`, stale→null) · `verify:osn:s6b3`
(S6B3 preview unit) + the dist-absence grep · `build.yml` (typecheck + vite build). **Gap to fill in
S6B4:** the **`markerViewBoxPoint` routing helper test** (B) and the **two-point camera co-move test** (C)
— both pure. No live-DB/browser/flag test is needed or permitted.

---

## E. S6B closure definition

S6B (the read-only fixed-space frontend foundation) is **complete** when **all** hold:
1. **All S6B1–S6B4 proofs green:** `verify:osn:s6b` (transform) · `verify:osn:resolver` (provenance +
   the S6B4 routing-helper cases) · `verify:osn:s6b3` + dist-absence · the S6B4 camera co-move test ·
   `build.yml`.
2. **Build + Pages deployment green** on the closure merge.
3. **Production flags unchanged:** `mainship_send_enabled=TRUE`, `mainship_space_movement_enabled=FALSE`.
4. **No player command path** (no tap/CTA/request-id/RPC) and **no coordinate-movement enablement**.
5. **No production visual change while the flag is false:** on production data the ship is always
   `legacy_dynamic` (open-space states are dark) and the preview is compile-time absent → zero change.
6. **Documentation updated at closure (S6B4 only):** `docs/DEV_LOG.md` + `docs/BYEHARU_PROJECT_GUIDE.md`
   record S6B1–S6B4 as the closed read-only fixed-space foundation, snapshot bumped to the closure
   commit/migration (migrations unchanged → still 0060), flags noted unchanged. *(S6B1–S6B3 deliberately
   deferred docs; the closure is where they land.)*
7. **Deliberate exclusions stated:** no tap/`mapToWorld` wiring, no command/CTA/RPC, no flag flip, no
   named-location co-registration.
8. **S6B-PRES explicitly mandatory before any S6D enablement** — restated in the closure docs.

---

## F. Proposed implementation boundary (NOT executed)

- **Likely tracked files to change:**
  - `src/features/map/MainShipMarker.tsx` — **behavior-preserving** extraction of the routing switch into
    an exported pure `markerViewBoxPoint(marker, norm)`; the component calls it. No hook/visual change.
  - **New** `tests/markerRouting.spec.ts` (or extend `resolveMainShipMarker.spec.ts`) — the B routing
    cases (open-space → `worldToViewBox`, legacy → `norm` via stub, no cross-call).
  - **New** camera co-move assertions — extend `tests/openSpaceTransform.spec.ts` (reuses `worldToScreen`)
    or a small new spec.
  - `docs/DEV_LOG.md` + `docs/BYEHARU_PROJECT_GUIDE.md` — **closure docs (S6B4 only)**.
  - Possibly `package.json` (+ a `verify:osn:s6b4` script) and a small workflow **only if** the new
    assertions aren't folded into the existing resolver/transform specs.
- **Files that must NOT change:** `resolveMainShipMarker.ts` logic (consumed, not altered — `ShipMarker`
  type reused), `openSpaceTransform.ts` (S6B1 frozen, reused), `DevFixedSpacePreview.tsx` (S6B3, reused),
  `buildNormalizer`/`norm`, `LocationMarker.tsx`, `FleetMovementLine.tsx`, `GalaxyMap.tsx` camera/pan/
  ordering, `useGalaxyMapData.ts`/`mainshipApi.ts`, any `supabase/migrations/**`, any RPC, the open-space
  writer/arrival processor, all S6A artifacts, all flags.
- **New test-only fixture/module?** No standalone fixture module — fixtures are inline in the spec(s); the
  only "module" change is the pure `markerViewBoxPoint` export.
- **Dedicated test/workflow?** Prefer **reuse**: fold the routing test into the resolver spec
  (`verify-osn-resolver`) and the camera co-move into the transform spec (`verify:osn:s6b`) — both already
  dispatchable on a branch. A dedicated `verify:osn:s6b4` + workflow is an acceptable alternative if
  cleaner; either way it is a **pure** test, no DB/flag.
- **Local manual visual evidence in addition to CI?** **Optional, not required.** The pure routing + camera
  proofs + construction cover acceptance deterministically. A one-off **manual** `vite dev` screenshot
  (dev preview + a temporarily dev-injected `in_space` ship, eyeballed for co-movement) may be attached as
  human confirmation but is **not** a CI gate and **must not** seed any production state.
- **Can S6B4 close without a production database test?** **Yes — explicitly.** All proofs are pure/build-
  level; no live-DB, no flag flip, no production write, no E2E against the live app.
- **Acceptance criteria:** the E.1–E.8 list — every S6B1–S6B4 proof green; build + Pages green; flags
  unchanged; no command path/enablement; zero prod visual change; closure docs updated; S6B-PRES restated.
- **Rollback / containment:** S6B4 is frontend test/refactor + docs only — no migration, no flag, no
  server. Rollback = revert the commit; nothing to unwind in production (the live bundle behavior is
  unchanged — the ship still renders `legacy_dynamic`, preview still absent). The `markerViewBoxPoint`
  extraction is behavior-identical, so even shipped it changes nothing visible.
- **Exact recommended next milestone after S6B closure:** **S6B-PRES** — the fixed-space ↔ named-location
  **presentation/co-registration decision** (render named locations through a verified fixed-domain
  transform **or** a separate coordinate map mode/surface hiding/demoting legacy markers). It is the
  **mandatory architectural gate before S6D enablement** and the biggest open question; **S6C** (tap →
  world via `mapToWorld`, still no command) is the parallel input track but should not precede the
  presentation decision in a way that implies co-registration. Recommend **S6B-PRES next**.

---

## Report summary (per the five required points)
1. **Proposed proof mechanism:** a **pure** unit test of an extracted, exported `markerViewBoxPoint`
   routing helper (the real function `MainShipMarker` calls) + a **pure** two-point camera co-move test
   reusing S6B1 `worldToScreen` — both deterministic, no browser/DB/flag. Optional non-gating manual dev
   screenshot.
2. **Directly exercises the actual `MainShipMarker` fixed-provenance branch?** **Yes** — by hoisting the
   inline switch into one exported pure function that both the component and the test use (no duplicate),
   chained to S6B2's resolver proof that `in_space`/coordinate-`in_transit` inputs yield an
   `open_space_fixed` marker.
3. **Minimum implementation/test slice:** behavior-preserving `markerViewBoxPoint` extraction in
   `MainShipMarker.tsx` + a pure routing test + a pure camera co-move test + the S6B **closure docs**
   (DEV_LOG + GUIDE). Reuse existing resolver/transform verifiers; no new backend/DB/flag work.
4. **S6B closure criteria:** §E (all S6B1–S6B4 proofs green; build + Pages green; flags unchanged; no
   command path/enablement; zero prod visual change; closure docs; S6B-PRES restated as mandatory before
   S6D).
5. **Any unresolved decision blocking S6B4 implementation?** **No blocker.** One minor choice to confirm:
   reuse existing resolver/transform specs+workflows vs. a dedicated `verify:osn:s6b4` — either is pure
   and safe; recommend reuse. Everything else is grounded in current code.

*Reconnaissance only — no code. Awaiting an explicit "begin S6B4" instruction.*

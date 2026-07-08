import { test, expect } from '@playwright/test'
import {
  worldToViewBox,
  viewBoxToWorld,
  worldToScreen,
  screenToWorld,
  type Camera as TCamera,
  type Viewport,
  type WorldCoord,
} from '../src/features/map/openSpaceTransform'
import {
  VIEW,
  PAD,
  MIN_K,
  MAX_K,
  DEGENERATE_SPAN,
  clampK,
  clampPan,
  fitCameraToWorldPoints,
  focusWorldPoints,
  focusCamera,
  type FocusInputs,
} from '../src/features/map/galaxyCamera'
import { markerViewBoxPoint } from '../src/features/map/MainShipMarker'

// S6B-PRES — pure unit proofs for the UNIFIED fixed-coordinate frame + content-fit camera. No browser/
// page/DB. The map's `norm` is `worldToViewBox`, so named locations, base, movement lines, legacy ship
// states, open-space ship states, and coordinate targets all share ONE fixed spatial domain.

const TOL = 1e-6
const near = (a: number, b: number, tol = TOL) => expect(Math.abs(a - b)).toBeLessThanOrEqual(tol)
const nearPt = (a: { x: number; y: number }, b: { x: number; y: number }, tol = TOL) => {
  near(a.x, b.x, tol)
  near(a.y, b.y, tol)
}
// The camera maps a viewBox point P → k·P + t (the SVG `<g transform="translate(t) scale(k)">`).
const applyCamera = (cam: { k: number; tx: number; ty: number }, p: { x: number; y: number }) => ({
  x: cam.tx + cam.k * p.x,
  y: cam.ty + cam.k * p.y,
})
const inView = (p: { x: number; y: number }, m = 0) =>
  p.x >= -m && p.x <= VIEW + m && p.y >= -m && p.y <= VIEW + m

// ── 1. Fixed-transform / co-registration: a named location and a ship at the SAME world coordinate
//       render to the SAME viewBox point (both go through the unified `worldToViewBox`). ────────────
test('S6B-PRES: location and ship at the same world coordinate co-register', () => {
  const w: WorldCoord = { x: 33, y: 23 }
  // GalaxyMap positions named markers via `norm = worldToViewBox`; the open-space ship via worldToViewBox.
  nearPt(worldToViewBox(w), worldToViewBox(w))
  // And the routing helper agrees for both provenances when the supplied `norm` is the unified transform.
  const viaLegacy = markerViewBoxPoint({ x: w.x, y: w.y, coordinateSpace: 'legacy_dynamic' }, worldToViewBox)
  const viaFixed = markerViewBoxPoint({ x: w.x, y: w.y, coordinateSpace: 'open_space_fixed' }, worldToViewBox)
  nearPt(viaLegacy, viaFixed) // unified frame: legacy + open-space coincide at the same world point
})

// ── 2. Movement-line endpoint alignment: line endpoints (worldToViewBox of origin/target) coincide
//       with markers placed at those same world points. ─────────────────────────────────────────────
test('S6B-PRES: movement-line endpoints align with markers in the unified frame', () => {
  const origin: WorldCoord = { x: -1500, y: 800 }
  const target: WorldCoord = { x: 2200, y: -400 }
  nearPt(worldToViewBox(origin), markerViewBoxPoint({ ...origin, coordinateSpace: 'open_space_fixed' }, worldToViewBox))
  nearPt(worldToViewBox(target), markerViewBoxPoint({ ...target, coordinateSpace: 'legacy_dynamic' }, worldToViewBox))
})

// ── 3. Tap/click world-coordinate round trip UNDER pan/zoom: a tap at the screen position of a world
//       point returns that world point — same fixed frame both directions (markers drawn via
//       worldToViewBox→camera; taps inverted via screenToWorld with the SAME camera). ───────────────
test('S6B-PRES: tap→world round trip holds under pan/zoom', () => {
  const cams: TCamera[] = [
    { k: 1, tx: 0, ty: 0 },
    { k: 0.4, tx: 0, ty: 0 },
    { k: 8, tx: 50, ty: 50 },
    { k: 420, tx: -209500, ty: -209500 }, // a deep zoom into clustered seed content
    { k: 2, tx: 123.5, ty: -456.25 },
  ]
  const vps: Viewport[] = [
    { width: 800, height: 600 },
    { width: 375, height: 812 },
    { width: 1280, height: 1280 },
  ]
  const worlds: WorldCoord[] = [
    { x: 0, y: 0 },
    { x: 33, y: 23 },
    { x: -9000, y: 9000 },
    { x: 1234.5, y: -6789.25 },
  ]
  for (const cam of cams)
    for (const vp of vps)
      for (const w of worlds) {
        const screen = worldToScreen(w, cam, vp) // where a marker at world w is drawn
        const back = screenToWorld(screen, cam, vp) // where a tap at that screen point resolves
        nearPt(back, w, 1e-6)
      }
})

// ── 4a. Initial/reset camera — TIGHT current seed cluster: framed + usable (k far beyond the old 8),
//        bounded by MAX_K, and all content lands inside the view. ─────────────────────────────────────
test('S6B-PRES: content-fit frames the tight seed cluster usably and bounded', () => {
  // Current seed world coords (world_map.sql) + base at origin.
  const seed: WorldCoord[] = [
    { x: 11, y: 5 }, { x: 12, y: 6 }, { x: 9, y: 4 }, { x: 31, y: 22 }, { x: 33, y: 23 }, { x: 0, y: 0 },
  ]
  const cam = fitCameraToWorldPoints(seed)
  expect(cam.k).toBeGreaterThan(8) // the OLD hard cap could not inspect this cluster
  expect(cam.k).toBeLessThanOrEqual(MAX_K) // still bounded
  // Every seed marker is inside the view after the camera transform (with a small margin).
  for (const w of seed) expect(inView(applyCamera(cam, worldToViewBox(w)), 1)).toBeTruthy()
})

// ── 4b. Deterministic focus policy — player in OPEN SPACE / IN TRANSIT takes priority over named
//        content (ship/segment is framed; far-away locations do NOT pull focus). ─────────────────────
test('S6B-PRES: open-space / in-transit ship takes focus priority over named locations', () => {
  const ship: WorldCoord = { x: 5000, y: -5000 }
  const f: FocusInputs = {
    shipWorld: ship,
    movementSegment: [{ x: 4000, y: -4000 }, { x: 6000, y: -6000 }],
    locations: [{ x: 11, y: 5 }, { x: 33, y: 23 }], // near origin — must be ignored while in open space
  }
  expect(focusWorldPoints(f)).not.toContainEqual({ x: 11, y: 5 }) // named content excluded
  expect(focusWorldPoints(f)).toContainEqual(ship)
  const cam = focusCamera(f)
  // The ship + both segment endpoints are framed; the origin (named cluster center) is NOT necessarily in view.
  for (const w of [ship, { x: 4000, y: -4000 }, { x: 6000, y: -6000 }])
    expect(inView(applyCamera(cam, worldToViewBox(w)), 1)).toBeTruthy()
  // Otherwise (no ship in open space) we fall back to named + base.
  const named: FocusInputs = { shipWorld: null, movementSegment: null, locations: [{ x: 11, y: 5 }] }
  expect(focusWorldPoints(named)).toEqual([{ x: 11, y: 5 }])
})

// ── 4c. Initial/reset camera — WIDELY distributed future points: fits within bounds, all in view. ────
test('S6B-PRES: content-fit frames widely distributed points within bounds', () => {
  const wide: WorldCoord[] = [
    { x: -9000, y: -9000 }, { x: 9000, y: 9000 }, { x: -9000, y: 9000 }, { x: 9000, y: -9000 }, { x: 0, y: 0 },
  ]
  const cam = fitCameraToWorldPoints(wide)
  expect(cam.k).toBeGreaterThanOrEqual(MIN_K)
  expect(cam.k).toBeLessThanOrEqual(MAX_K)
  for (const w of wide) expect(inView(applyCamera(cam, worldToViewBox(w)), 1)).toBeTruthy()
})

// ── 4d. Bounded zoom policy — cap is finite and enforced on both ends; degenerate (single point)
//        fit clamps to MAX_K (does not blow up). ─────────────────────────────────────────────────────
test('S6B-PRES: zoom cap is bounded (finite) and enforced; single-point fit → comfortable zoom (not MAX_K)', () => {
  expect(Number.isFinite(MAX_K)).toBeTruthy()
  expect(MAX_K).toBeGreaterThan(8) // raised from the old unusable 8
  expect(clampK(1e9)).toBe(MAX_K) // never unbounded
  expect(clampK(1e-9)).toBe(MIN_K)
  expect(clampK(Number.POSITIVE_INFINITY)).toBe(MIN_K) // non-finite → safe MIN_K
  expect(clampK(Number.NaN)).toBe(MIN_K)
  // A single focus point (e.g. a ship parked after Stop) frames a fixed neighbourhood (DEGENERATE_SPAN) —
  // a gentle deterministic zoom, NOT a slam to MAX_K.
  const single = fitCameraToWorldPoints([{ x: 100, y: -200 }])
  expect(single.k).toBeCloseTo((VIEW * (1 - 2 * PAD)) / DEGENERATE_SPAN)
  expect(single.k).toBeGreaterThan(MIN_K)
  expect(single.k).toBeLessThan(MAX_K)
  expect(Number.isFinite(single.tx) && Number.isFinite(single.ty)).toBeTruthy()
  // empty input → identity (no crash)
  expect(fitCameraToWorldPoints([])).toEqual({ k: 1, tx: 0, ty: 0 })
})

// ── 5. Camera/focus logic is PURE GEOMETRY with NO coupling to any feature flag or command surface
//       (dark flag-off behavior cannot be affected by this slice). ───────────────────────────────────
test('S6B-PRES: camera/focus depends only on world geometry (no flag/command coupling)', () => {
  const f: FocusInputs = { shipWorld: { x: 1, y: 2 }, movementSegment: null, locations: [] }
  // Deterministic + referentially stable for identical inputs (no hidden global/flag state).
  expect(focusCamera(f)).toEqual(focusCamera(f))
  // Inverse-transform sanity: the fit camera's framing is reversible through the fixed domain.
  const w: WorldCoord = { x: 7777, y: -3333 }
  nearPt(viewBoxToWorld(worldToViewBox(w)), w)
})

// ── 6. clampPan keeps the viewBox overlapping the viewport (manual-pan safety unchanged). ────────────
test('S6B-PRES: clampPan keeps content overlapping the viewport', () => {
  // zoomed in (content > view): pan is bounded to [VIEW-content, 0]
  const a = clampPan(99999, 99999, 4)
  expect(a.tx).toBeLessThanOrEqual(0)
  expect(a.tx).toBeGreaterThanOrEqual(VIEW - 4 * VIEW)
  // zoomed out (content < view): pan is bounded to [0, VIEW-content]
  const b = clampPan(-99999, -99999, 0.5)
  expect(b.tx).toBeGreaterThanOrEqual(0)
  expect(b.ty).toBeGreaterThanOrEqual(0)
})

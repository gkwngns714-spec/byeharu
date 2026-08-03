import { test, expect } from '@playwright/test'
import {
  worldToViewBox,
  viewBoxToWorld,
  worldToScreen,
  screenToWorld,
  screenToViewBoxRaw,
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
  WHEEL_ZOOM_STEP,
  BUTTON_ZOOM_STEP,
  clampK,
  clampPan,
  zoomCameraAbout,
  fitCameraToWorldPoints,
  focusWorldPoints,
  focusCamera,
  type FocusInputs,
} from '../src/features/map/galaxyCamera'

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

// ── 1. Fixed-transform / co-registration ─────────────────────────────────────────────────────────
// (4C-CLIENT: the co-registration tests via markerViewBoxPoint were deleted with the per-ship
// marker pipeline — every marker layer projects through the ONE worldToViewBox `norm` now, so
// co-registration is structural rather than a routing property to prove.)

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

// ══ ZOOM-AT-THE-CURSOR ═══════════════════════════════════════════════════════════════════════════════
// `zoomCameraAbout` is the ONE zoom authority for both SVG map surfaces (the game map and the World
// Editor). Before this suite existed, `zoomByFactor` had ZERO coverage in EITHER of its two
// copy-pasted implementations — which is exactly how cursor-anchored zoom came to exist in the editor
// and silently NOT in the game the player actually plays. These tests pin the FEATURE, not the code.

// A wheel gesture's anchor, derived the way useWheelZoom derives it: the cursor pixel, letterbox
// undone, camera NOT undone (the anchor lives in the same space as tx/ty).
const anchorAtScreenOf = (w: WorldCoord, cam: TCamera, vp: Viewport) =>
  screenToViewBoxRaw(worldToScreen(w, cam, vp), vp)

// ── 7. THE FEATURE: the world point under the cursor does not move when you zoom. ────────────────────
//      Composed through worldToViewBox → camera → letterbox, i.e. the real render pipeline, and
//      asserted on the SCREEN position, which is what the player actually sees.
test('ZOOM-ANCHOR: the world point under the cursor holds its screen position, zooming IN and OUT', () => {
  const vp: Viewport = { width: 1600, height: 900 } // deliberately non-square: the letterbox is live
  const cam: TCamera = { k: 4, tx: -1500, ty: -1500 }
  const world: WorldCoord = { x: 2000, y: 2000 } // sits at viewBox (600,400) → on-screen under the camera
  const before = worldToScreen(world, cam, vp)
  const anchor = anchorAtScreenOf(world, cam, vp)

  for (const factor of [WHEEL_ZOOM_STEP, 1 / WHEEL_ZOOM_STEP, BUTTON_ZOOM_STEP, 1 / BUTTON_ZOOM_STEP]) {
    const next = zoomCameraAbout(cam, factor, anchor)
    expect(next.k).toBeCloseTo(cam.k * factor, 9) // the zoom really happened
    nearPt(worldToScreen(world, next, vp), before, 1e-9) // …and the anchored point did not move
  }

  // And it must hold across a MULTI-NOTCH scroll — drift only shows up when notches compound.
  let rolling = cam
  for (let i = 0; i < 10; i++) rolling = zoomCameraAbout(rolling, WHEEL_ZOOM_STEP, anchor)
  expect(rolling.k).toBeCloseTo(cam.k * WHEEL_ZOOM_STEP ** 10, 9)
  nearPt(worldToScreen(world, rolling, vp), before, 1e-9)
})

// ── 7b. The same property at a DIFFERENT anchor: a cursor away from the centre is the whole point.
//       (A centre-anchored zoom passes 7 only if the cursor happens to be at the centre.) ────────────
test('ZOOM-ANCHOR: holds for cursors all over the map, and a CENTRE anchor is the one that drifts', () => {
  const vp: Viewport = { width: 1280, height: 720 }
  const cam: TCamera = { k: 6, tx: -2200, ty: -2600 }
  const worlds: WorldCoord[] = [
    { x: 1000, y: 1000 },
    { x: 1200, y: 800 },
    { x: 900, y: 1400 },
  ]
  for (const w of worlds) {
    const before = worldToScreen(w, cam, vp)
    const zoomed = zoomCameraAbout(cam, WHEEL_ZOOM_STEP, anchorAtScreenOf(w, cam, vp))
    nearPt(worldToScreen(w, zoomed, vp), before, 1e-9)
    // The regression this replaces: the SAME notch with the OLD centre anchor moves that point.
    const centred = zoomCameraAbout(cam, WHEEL_ZOOM_STEP, null)
    const after = worldToScreen(w, centred, vp)
    expect(Math.hypot(after.x - before.x, after.y - before.y)).toBeGreaterThan(1)
  }
})

// ── 8. A null / omitted anchor reproduces the PREVIOUS centre-anchored behaviour EXACTLY. ────────────
test('ZOOM-ANCHOR: no anchor === the old centre-anchored formula, to the last bit', () => {
  // The formula GalaxyMap.tsx carried before this slice, transcribed verbatim.
  const legacyCentreZoom = (v: TCamera, factor: number): TCamera => {
    const k = clampK(v.k * factor)
    const ratio = k / v.k
    const cx = VIEW / 2
    const cy = VIEW / 2
    return { k, ...clampPan(cx - (cx - v.tx) * ratio, cy - (cy - v.ty) * ratio, k) }
  }
  const cams: TCamera[] = [
    { k: 1, tx: 0, ty: 0 },
    { k: 4, tx: -1500, ty: -1500 },
    { k: 0.5, tx: 300, ty: 120 },
    { k: 420, tx: -209500, ty: -209500 },
    { k: MIN_K, tx: 0, ty: 0 },
    { k: MAX_K, tx: -100000, ty: -100000 },
  ]
  for (const cam of cams)
    for (const factor of [1.15, 1 / 1.15, WHEEL_ZOOM_STEP, 1 / WHEEL_ZOOM_STEP, BUTTON_ZOOM_STEP, 1 / BUTTON_ZOOM_STEP]) {
      expect(zoomCameraAbout(cam, factor)).toEqual(legacyCentreZoom(cam, factor)) // omitted
      expect(zoomCameraAbout(cam, factor, null)).toEqual(legacyCentreZoom(cam, factor)) // explicit null
    }
  // Pinned against literal numbers too, so a future "equivalent" rewrite of BOTH sides cannot drift.
  expect(zoomCameraAbout({ k: 4, tx: -1500, ty: -1500 }, 1.15)).toEqual({ k: 4.6, tx: -1800, ty: -1800 })
})

// ── 9. The steps are the ONE shared pair, and the wheel is the gentle one. ───────────────────────────
test('ZOOM-ANCHOR: one shared wheel step (1.07) and one shared button step (1.25)', () => {
  expect(WHEEL_ZOOM_STEP).toBe(1.07)
  expect(BUTTON_ZOOM_STEP).toBe(1.25)
  // The wheel step must stay far gentler than a button click: a scroll is many notches, and 1.15 was
  // already measured to overshoot across a multi-notch gesture.
  expect(WHEEL_ZOOM_STEP).toBeLessThan(BUTTON_ZOOM_STEP)
  expect(WHEEL_ZOOM_STEP).toBeLessThan(1.15)
})

// ── 10. clampK still bounds BOTH ends through the anchored path. ─────────────────────────────────────
test('ZOOM-ANCHOR: clampK bounds both ends, and a capped zoom is a no-op that still holds the anchor', () => {
  const anchor = { x: 875, y: 125 }
  expect(zoomCameraAbout({ k: 1, tx: 0, ty: 0 }, 1e9, anchor).k).toBe(MAX_K)
  expect(zoomCameraAbout({ k: 1, tx: 0, ty: 0 }, 1e-9, anchor).k).toBe(MIN_K)
  expect(zoomCameraAbout({ k: MAX_K, tx: -100, ty: -100 }, 2, anchor).k).toBe(MAX_K)
  expect(zoomCameraAbout({ k: MIN_K, tx: 100, ty: 100 }, 0.5, anchor).k).toBe(MIN_K)
  // At the cap the ratio collapses to 1, so the camera does not move at all (no anchor-driven drift
  // while the player keeps scrolling against the stop).
  const atCap: TCamera = { k: MAX_K, tx: -100, ty: -100 }
  expect(zoomCameraAbout(atCap, 2, anchor)).toEqual(atCap)
  // Non-finite factor cannot poison the camera (clampK's non-finite → MIN_K rule still applies).
  expect(Number.isFinite(zoomCameraAbout({ k: 1, tx: 0, ty: 0 }, Number.NaN, anchor).k)).toBeTruthy()
})

// ── 11. clampPan still WINS at the world edge, even when the anchor pulls outward. ───────────────────
//       Real case: the cursor sits in the letterbox margin, so the anchor is outside [0, VIEW].
test('ZOOM-ANCHOR: clampPan overrides the anchor at the world edge', () => {
  const outward = { x: 2 * VIEW, y: 2 * VIEW } // a cursor beyond the drawn square
  const res = zoomCameraAbout({ k: 1, tx: 0, ty: 0 }, 2, outward)
  expect(res.k).toBe(2)
  // Unclamped the anchor would demand tx = 2000 - 2000·2 = -2000; the pan bound is VIEW - k·VIEW.
  expect(res.tx).toBe(VIEW - 2 * VIEW)
  expect(res.ty).toBe(VIEW - 2 * VIEW)
  // The invariant clampPan exists for: the viewBox still overlaps the viewport, never dragged off.
  for (const cam of [res, zoomCameraAbout({ k: 0.5, tx: 0, ty: 0 }, 1 / 4, { x: -9999, y: -9999 })]) {
    const bound = clampPan(cam.tx, cam.ty, cam.k)
    expect(cam.tx).toBe(bound.tx)
    expect(cam.ty).toBe(bound.ty)
  }
})

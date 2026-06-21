import { test, expect } from '@playwright/test'
import {
  worldToViewBox,
  viewBoxToWorld,
  viewBoxToScreen,
  screenToViewBox,
  worldToScreen,
  screenToWorld,
  viewBoxDisplayRect,
  isWithinOpenSpaceBounds,
  WORLD_MIN,
  WORLD_MAX,
  VIEWBOX_SIZE,
  type Camera,
  type Viewport,
  type WorldCoord,
} from '../src/features/map/openSpaceTransform'

// OSN-3 S6B1 — pure unit tests for the fixed-domain open-space coordinate transform. No browser/page,
// no DB, no DOM, no integer-pixel quantization. Run: `npm run verify:osn:s6b`.
//
// Two distinct round-trip categories (per the S6B charter Amendment §4):
//   • pure world ↔ viewBox      — absolute error ≤ 1e-6 world units;
//   • full world ↔ screen       — absolute error ≤ 1e-6 world units (no pixel quantization introduced).
// Any browser/pointer pixel-rounding tolerance is an S6C concern and is NOT used here.

const TOL = 1e-6
const near = (a: number, b: number, tol = TOL) => expect(Math.abs(a - b)).toBeLessThanOrEqual(tol)
const nearPt = (a: { x: number; y: number }, b: { x: number; y: number }, tol = TOL) => {
  near(a.x, b.x, tol)
  near(a.y, b.y, tol)
}

// Representative camera + viewport sets (pure values — pan is NOT clamped by this module).
const CAMERAS: Camera[] = [
  { k: 0.4, tx: 0, ty: 0 }, // current min zoom
  { k: 1, tx: 0, ty: 0 }, // identity
  { k: 1, tx: 123.5, ty: -456.25 }, // nonzero pan
  { k: 2, tx: -200, ty: 350 },
  { k: 8, tx: 50, ty: 50 }, // current max zoom
]
const VIEWPORTS: Viewport[] = [
  { width: 800, height: 800 }, // square
  { width: 1200, height: 400 }, // wide / landscape letterbox
  { width: 400, height: 1200 }, // tall / portrait letterbox
  { width: 390, height: 844 }, // mobile portrait
  { width: 844, height: 390 }, // mobile landscape
]
const WORLD_SAMPLES: WorldCoord[] = [
  { x: -10000, y: -10000 },
  { x: -10000, y: 10000 },
  { x: 10000, y: -10000 },
  { x: 10000, y: 10000 },
  { x: 0, y: 0 },
  { x: 9999, y: -9999 },
  { x: -9999, y: 9999 },
  { x: 1234.5, y: -6789.25 },
  { x: -42, y: 17 },
]

// ── Fixed world → viewBox: exact corners + centre ───────────────────────────────────────────────────

test('worldToViewBox: four exact corners (with Y inversion)', () => {
  nearPt(worldToViewBox({ x: -10000, y: -10000 }), { x: 0, y: VIEWBOX_SIZE }) // bottom-left → (0,1000)
  nearPt(worldToViewBox({ x: -10000, y: 10000 }), { x: 0, y: 0 }) // top-left → (0,0)
  nearPt(worldToViewBox({ x: 10000, y: -10000 }), { x: VIEWBOX_SIZE, y: VIEWBOX_SIZE }) // bottom-right
  nearPt(worldToViewBox({ x: 10000, y: 10000 }), { x: VIEWBOX_SIZE, y: 0 }) // top-right → (1000,0)
})

test('worldToViewBox: centre maps to (500,500)', () => {
  nearPt(worldToViewBox({ x: 0, y: 0 }), { x: 500, y: 500 })
})

test('worldToViewBox: near-boundary / off-by-one values', () => {
  near(worldToViewBox({ x: 9999, y: 0 }).x, 999.95)
  near(worldToViewBox({ x: 10000, y: 0 }).x, 1000)
  near(worldToViewBox({ x: -9999, y: 0 }).x, 0.05)
  near(worldToViewBox({ x: -10000, y: 0 }).x, 0)
})

test('Y orientation: increasing world-y moves UP (smaller viewBox-y)', () => {
  const lowY = worldToViewBox({ x: 0, y: 0 }).y
  const highY = worldToViewBox({ x: 0, y: 5000 }).y
  expect(highY).toBeLessThan(lowY) // larger world-y → smaller SVG y → higher on screen
  near(highY, 250)
  near(lowY, 500)
})

// ── Pure round trips: world ↔ viewBox (≤ 1e-6 world units) ──────────────────────────────────────────

test('pure round trip: viewBoxToWorld(worldToViewBox(P)) ≈ P', () => {
  for (const p of WORLD_SAMPLES) nearPt(viewBoxToWorld(worldToViewBox(p)), p)
})

test('pure round trip: worldToViewBox(viewBoxToWorld(V)) ≈ V', () => {
  for (const v of [
    { x: 0, y: 0 },
    { x: 1000, y: 1000 },
    { x: 500, y: 500 },
    { x: 12.3, y: 987.65 },
    { x: 999.95, y: 0.05 },
  ]) {
    nearPt(worldToViewBox(viewBoxToWorld(v)), v)
  }
})

// ── preserveAspectRatio letterbox geometry (does NOT assume width === height) ────────────────────────

test('viewBoxDisplayRect: square viewport — full fit, no offset', () => {
  const r = viewBoxDisplayRect({ width: 800, height: 800 })
  near(r.scale, 0.8)
  near(r.size, 800)
  near(r.offsetX, 0)
  near(r.offsetY, 0)
})

test('viewBoxDisplayRect: wide viewport letterboxes horizontally (xMid centred)', () => {
  const r = viewBoxDisplayRect({ width: 1200, height: 400 })
  near(r.scale, 0.4)
  near(r.size, 400)
  near(r.offsetX, 400) // (1200-400)/2
  near(r.offsetY, 0)
})

test('viewBoxDisplayRect: tall viewport letterboxes vertically (yMid centred)', () => {
  const r = viewBoxDisplayRect({ width: 400, height: 1200 })
  near(r.scale, 0.4)
  near(r.size, 400)
  near(r.offsetX, 0)
  near(r.offsetY, 400) // (1200-400)/2
})

test('viewBox centre maps to the element centre under identity camera (any aspect)', () => {
  const id: Camera = { k: 1, tx: 0, ty: 0 }
  for (const vp of VIEWPORTS) {
    nearPt(viewBoxToScreen({ x: 500, y: 500 }, id, vp), { x: vp.width / 2, y: vp.height / 2 })
  }
})

// ── Camera composition order: scale THEN translate (cameraPoint = tx + k·viewBoxX) ──────────────────

test('camera order matches GalaxyMap <g translate(tx ty) scale(k)>', () => {
  // 1000×1000 viewport → letterbox scale 1, zero offsets → screen == camera-applied viewBox units.
  const vp: Viewport = { width: 1000, height: 1000 }
  const cam: Camera = { k: 2, tx: 10, ty: 20 }
  const vb = worldToViewBox({ x: 0, y: 0 }) // (500,500)
  nearPt(viewBoxToScreen(vb, cam, vp), { x: cam.tx + cam.k * vb.x, y: cam.ty + cam.k * vb.y }) // (1010,1020)
  nearPt(worldToScreen({ x: 0, y: 0 }, cam, vp), { x: 1010, y: 1020 })
})

// ── Full round trips: world ↔ screen across cameras × viewports (≤ 1e-6 world units) ────────────────

test('full round trip: screenToWorld(worldToScreen(P)) ≈ P over all camera×viewport combos', () => {
  for (const cam of CAMERAS) {
    for (const vp of VIEWPORTS) {
      for (const p of WORLD_SAMPLES) {
        nearPt(screenToWorld(worldToScreen(p, cam, vp), cam, vp), p)
      }
    }
  }
})

test('full round trip: screenToViewBox(viewBoxToScreen(V)) ≈ V', () => {
  for (const cam of CAMERAS) {
    for (const vp of VIEWPORTS) {
      for (const v of [
        { x: 0, y: 0 },
        { x: 1000, y: 1000 },
        { x: 500, y: 500 },
        { x: 250.5, y: 750.25 },
      ]) {
        nearPt(screenToViewBox(viewBoxToScreen(v, cam, vp), cam, vp), v)
      }
    }
  }
})

// ── Safeguard 1: no hidden clamping; explicit non-finite + out-of-domain behavior ───────────────────

test('out-of-domain world coords convert WITHOUT clamping', () => {
  const hi = worldToViewBox({ x: 20000, y: 0 }).x
  near(hi, 1500)
  expect(hi).toBeGreaterThan(VIEWBOX_SIZE) // explicitly NOT snapped into [0,1000]
  const lo = worldToViewBox({ x: -20000, y: 0 }).x
  near(lo, -500)
  expect(lo).toBeLessThan(0) // explicitly NOT snapped into [0,1000]
  // viewBox values outside [0,1000] invert back to out-of-domain world coords, also unclamped.
  near(viewBoxToWorld({ x: 1500, y: 500 }).x, 20000)
})

test('non-finite inputs propagate (NaN/±Inf) and never throw', () => {
  expect(Number.isNaN(worldToViewBox({ x: NaN, y: 0 }).x)).toBe(true)
  expect(worldToViewBox({ x: Infinity, y: 0 }).x).toBe(Infinity)
  expect(worldToViewBox({ x: -Infinity, y: 0 }).x).toBe(-Infinity)
  // screen inverse with non-finite screen also propagates, no throw.
  expect(Number.isNaN(screenToWorld({ x: NaN, y: 0 }, { k: 1, tx: 0, ty: 0 }, { width: 800, height: 800 }).x)).toBe(true)
})

// ── Safeguard separation: bounds validation is its own predicate, never inferred from conversion ─────

test('isWithinOpenSpaceBounds: in-domain, edges, out-of-domain, non-finite', () => {
  expect(isWithinOpenSpaceBounds({ x: 0, y: 0 })).toBe(true)
  expect(isWithinOpenSpaceBounds({ x: WORLD_MIN, y: WORLD_MAX })).toBe(true) // inclusive edges
  expect(isWithinOpenSpaceBounds({ x: 10000.0001, y: 0 })).toBe(false)
  expect(isWithinOpenSpaceBounds({ x: -10000.0001, y: 0 })).toBe(false)
  expect(isWithinOpenSpaceBounds({ x: NaN, y: 0 })).toBe(false)
  expect(isWithinOpenSpaceBounds({ x: Infinity, y: 0 })).toBe(false)
  expect(isWithinOpenSpaceBounds({ x: 20000, y: 0 })).toBe(false)
})

// ── OSN-3 S6B4: fixed-layer camera CO-MOVEMENT — the S6B3 preview fixture and a distinct fixed-space ship
// point preserve their relative geometry through the SAME camera/viewport transform across pan/zoom/
// viewports. Pure geometry only; NO comparison against dynamically-normalized named-location coordinates.

test('S6B4: preview + fixed-space ship co-move (screen Δ = letterbox·zoom × viewBox Δ) across pan/zoom/viewports', () => {
  const PREVIEW = { x: 8000, y: -8000 } // the S6B3 dev-preview fixture
  const SHIP = { x: -4000, y: 2000 } // a distinct fixed-space ship point (≠ the preview)
  const vbA = worldToViewBox(PREVIEW)
  const vbB = worldToViewBox(SHIP)
  const vbDelta = { x: vbB.x - vbA.x, y: vbB.y - vbA.y } // camera-independent (fixed layer)
  for (const cam of CAMERAS) {
    // CAMERAS covers zoom 0.4 / 1 / 2 / 8 and both zero pan and nonzero pan
    for (const vp of VIEWPORTS) {
      // VIEWPORTS covers square / wide / tall / mobile-portrait / mobile-landscape
      const sA = worldToScreen(PREVIEW, cam, vp)
      const sB = worldToScreen(SHIP, cam, vp)
      const s = viewBoxDisplayRect(vp).scale
      // both points feed worldToViewBox → the same camera <g> (scale-then-translate) → the same letterbox,
      // so their SCREEN-space relative vector equals the viewBox-relative vector scaled by (letterbox·zoom).
      // The pan term cancels in the delta → pan-invariant; consistent across every viewport/zoom.
      near(sB.x - sA.x, s * cam.k * vbDelta.x)
      near(sB.y - sA.y, s * cam.k * vbDelta.y)
    }
  }
})

import { test, expect } from '@playwright/test'
import {
  segmentsProperlyIntersect,
  polygonSelfIntersects,
  pointInPolygon,
  pointInCircle,
  polygonArea,
  circleBbox,
} from '../src/features/worldeditor/zoneGeometryMath'

// WORLD EDITOR V3A PR-1 — zoneGeometryMath is PURE planar geometry over world coords (props in →
// decision out; no React/DOM/IO, no clamping, no throwing). Table-driven proofs, no DB.
// Run: `npx playwright test zoneGeometryMath.spec.ts`.

// ── segmentsProperlyIntersect ────────────────────────────────────────────────────────────────────────

const SEGMENT_CASES: {
  name: string
  a: { x: number; y: number }
  b: { x: number; y: number }
  c: { x: number; y: number }
  d: { x: number; y: number }
  expected: boolean
}[] = [
  {
    name: 'X-crossing segments properly intersect',
    a: { x: 0, y: 0 }, b: { x: 10, y: 10 }, c: { x: 0, y: 10 }, d: { x: 10, y: 0 },
    expected: true,
  },
  {
    name: 'parallel separated segments do not intersect',
    a: { x: 0, y: 0 }, b: { x: 10, y: 0 }, c: { x: 0, y: 5 }, d: { x: 10, y: 5 },
    expected: false,
  },
  {
    name: 'far-apart segments do not intersect',
    a: { x: 0, y: 0 }, b: { x: 1, y: 1 }, c: { x: 100, y: 100 }, d: { x: 101, y: 99 },
    expected: false,
  },
  {
    name: 'endpoint-to-endpoint touch is NOT proper (how adjacent edges legitimately meet)',
    a: { x: 0, y: 0 }, b: { x: 10, y: 0 }, c: { x: 10, y: 0 }, d: { x: 20, y: 5 },
    expected: false,
  },
  {
    name: 'T-touch (endpoint strictly inside the other segment) IS proper',
    a: { x: 0, y: 0 }, b: { x: 10, y: 0 }, c: { x: 5, y: 0 }, d: { x: 5, y: 10 },
    expected: true,
  },
  {
    name: 'collinear with positive-length overlap IS proper',
    a: { x: 0, y: 0 }, b: { x: 10, y: 0 }, c: { x: 5, y: 0 }, d: { x: 15, y: 0 },
    expected: true,
  },
  {
    name: 'collinear touching only at one endpoint is NOT proper',
    a: { x: 0, y: 0 }, b: { x: 10, y: 0 }, c: { x: 10, y: 0 }, d: { x: 20, y: 0 },
    expected: false,
  },
  {
    name: 'collinear disjoint segments do not intersect',
    a: { x: 0, y: 0 }, b: { x: 10, y: 0 }, c: { x: 20, y: 0 }, d: { x: 30, y: 0 },
    expected: false,
  },
  {
    name: 'vertical collinear overlap IS proper (dominant-axis projection covers x-degenerate lines)',
    a: { x: 3, y: 0 }, b: { x: 3, y: 10 }, c: { x: 3, y: 5 }, d: { x: 3, y: 15 },
    expected: true,
  },
]

for (const { name, a, b, c, d, expected } of SEGMENT_CASES) {
  test(`segmentsProperlyIntersect: ${name}`, () => {
    expect(segmentsProperlyIntersect(a, b, c, d)).toBe(expected)
    // Symmetric in segment order.
    expect(segmentsProperlyIntersect(c, d, a, b)).toBe(expected)
  })
}

// ── polygonSelfIntersects ────────────────────────────────────────────────────────────────────────────

const SQUARE = [
  { x: 0, y: 0 },
  { x: 100, y: 0 },
  { x: 100, y: 100 },
  { x: 0, y: 100 },
]

// The classic bowtie: (0,0)→(100,100)→(100,0)→(0,100) — edges 0-1 and 2-3 cross.
const BOWTIE = [
  { x: 0, y: 0 },
  { x: 100, y: 100 },
  { x: 100, y: 0 },
  { x: 0, y: 100 },
]

const SELF_INTERSECT_CASES: { name: string; vertices: { x: number; y: number }[]; expected: boolean }[] = [
  { name: 'simple square is clean', vertices: SQUARE, expected: false },
  { name: 'bowtie self-intersects', vertices: BOWTIE, expected: true },
  { name: 'triangle is clean (no non-adjacent edge pairs exist)', vertices: SQUARE.slice(0, 3), expected: false },
  { name: 'fewer than 3 vertices is not a polygon → false', vertices: SQUARE.slice(0, 2), expected: false },
  {
    name: 'convex pentagon is clean (wrap pair correctly skipped)',
    vertices: [
      { x: 0, y: 0 },
      { x: 100, y: 0 },
      { x: 130, y: 80 },
      { x: 50, y: 140 },
      { x: -30, y: 80 },
    ],
    expected: false,
  },
  {
    name: 'concave (but simple) arrowhead is clean',
    vertices: [
      { x: 0, y: 0 },
      { x: 100, y: 0 },
      { x: 50, y: 40 }, // dents inward — concave, still simple
      { x: 50, y: 100 },
    ],
    expected: false,
  },
  {
    name: 'edge crossing a non-adjacent edge is caught mid-ring (5-vertex twist)',
    vertices: [
      { x: 0, y: 0 },
      { x: 100, y: 0 },
      { x: 100, y: 100 },
      { x: 50, y: -50 }, // dives across the bottom edge 0-1
      { x: 0, y: 100 },
    ],
    expected: true,
  },
]

for (const { name, vertices, expected } of SELF_INTERSECT_CASES) {
  test(`polygonSelfIntersects: ${name}`, () => {
    expect(polygonSelfIntersects(vertices)).toBe(expected)
  })
}

// ── pointInPolygon ───────────────────────────────────────────────────────────────────────────────────

const POINT_IN_POLYGON_CASES: { name: string; p: { x: number; y: number }; expected: boolean }[] = [
  { name: 'center is inside', p: { x: 50, y: 50 }, expected: true },
  { name: 'outside right is outside', p: { x: 150, y: 50 }, expected: false },
  { name: 'outside above is outside', p: { x: 50, y: 150 }, expected: false },
  { name: 'far negative is outside', p: { x: -1, y: -1 }, expected: false },
  { name: 'on an edge is inside (boundary-inclusive)', p: { x: 50, y: 0 }, expected: true },
  { name: 'on a vertex is inside (boundary-inclusive)', p: { x: 0, y: 0 }, expected: true },
  { name: 'just inside an edge is inside', p: { x: 50, y: 0.001 }, expected: true },
  { name: 'just outside an edge is outside', p: { x: 50, y: -0.001 }, expected: false },
]

for (const { name, p, expected } of POINT_IN_POLYGON_CASES) {
  test(`pointInPolygon (unit square 0..100): ${name}`, () => {
    expect(pointInPolygon(p, SQUARE)).toBe(expected)
  })
}

test('pointInPolygon: concave polygon — the notch is outside, the wings are inside', () => {
  // U-shape: notch cut into the top between x=40..60 down to y=40.
  const U = [
    { x: 0, y: 0 },
    { x: 100, y: 0 },
    { x: 100, y: 100 },
    { x: 60, y: 100 },
    { x: 60, y: 40 },
    { x: 40, y: 40 },
    { x: 40, y: 100 },
    { x: 0, y: 100 },
  ]
  expect(pointInPolygon({ x: 50, y: 80 }, U)).toBe(false) // inside the notch → outside the shape
  expect(pointInPolygon({ x: 20, y: 80 }, U)).toBe(true) // left wing
  expect(pointInPolygon({ x: 80, y: 80 }, U)).toBe(true) // right wing
  expect(pointInPolygon({ x: 50, y: 20 }, U)).toBe(true) // base
})

test('pointInPolygon: fewer than 3 vertices has no interior → false', () => {
  expect(pointInPolygon({ x: 0, y: 0 }, [{ x: 0, y: 0 }, { x: 10, y: 0 }])).toBe(false)
})

// ── pointInCircle ────────────────────────────────────────────────────────────────────────────────────

const CIRCLE_CASES: { name: string; p: { x: number; y: number }; expected: boolean }[] = [
  { name: 'center is inside', p: { x: 10, y: -20 }, expected: true },
  { name: 'interior point is inside', p: { x: 40, y: -20 }, expected: true },
  { name: 'point exactly ON the boundary is inside (closed disc)', p: { x: 60, y: -20 }, expected: true },
  { name: 'boundary point off-axis (3-4-5) is inside', p: { x: 40, y: 20 }, expected: true },
  { name: 'just outside the boundary is outside', p: { x: 60.001, y: -20 }, expected: false },
  { name: 'far away is outside', p: { x: 1000, y: 1000 }, expected: false },
]

for (const { name, p, expected } of CIRCLE_CASES) {
  test(`pointInCircle (center (10,-20), r=50): ${name}`, () => {
    expect(pointInCircle(p, { x: 10, y: -20 }, 50)).toBe(expected)
  })
}

// ── polygonArea ──────────────────────────────────────────────────────────────────────────────────────

test('polygonArea: 100×100 square (CCW) → 10000', () => {
  expect(polygonArea(SQUARE)).toBeCloseTo(10000, 9)
})

test('polygonArea: orientation-independent — the reversed (CW) square answers the same', () => {
  expect(polygonArea([...SQUARE].reverse())).toBeCloseTo(10000, 9)
})

test('polygonArea: right triangle legs 100,100 → 5000', () => {
  expect(polygonArea([{ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 0, y: 100 }])).toBeCloseTo(5000, 9)
})

test('polygonArea: collinear/degenerate ring ≈ 0', () => {
  expect(polygonArea([{ x: 0, y: 0 }, { x: 50, y: 50 }, { x: 100, y: 100 }])).toBeCloseTo(0, 9)
})

test('polygonArea: fewer than 3 vertices → 0', () => {
  expect(polygonArea([])).toBe(0)
  expect(polygonArea([{ x: 5, y: 5 }])).toBe(0)
  expect(polygonArea([{ x: 0, y: 0 }, { x: 10, y: 10 }])).toBe(0)
})

// ── circleBbox ───────────────────────────────────────────────────────────────────────────────────────

test('circleBbox: center ± radius on both axes', () => {
  expect(circleBbox({ x: 100, y: -200 }, 50)).toEqual({ minX: 50, minY: -250, maxX: 150, maxY: -150 })
})

test('circleBbox: zero radius collapses to the center point', () => {
  expect(circleBbox({ x: 7, y: 9 }, 0)).toEqual({ minX: 7, minY: 9, maxX: 7, maxY: 9 })
})

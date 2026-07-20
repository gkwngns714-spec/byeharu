// WORLD EDITOR — V3A PR-1 ZONE GEOMETRY MATH. PURE planar geometry over CANONICAL WORLD coordinates
// (props in → decision out): the unit-testable predicates the zone authoring slices build on —
// self-intersection rejection for owner-drawn rings, containment for point-in-zone questions, area
// for degenerate-ring rejection, bbox for circle framing. No React, no DOM, no IO, no clamping, no
// throwing — non-finite inputs propagate arithmetically (the openSpaceTransform "garbage in,
// garbage out; validation is a SEPARATE concern" law). This module DECIDES; it never draws
// (rendering is DraftPreviewOverlay / the map layers) and it never validates domain bounds
// (that is isWithinOpenSpaceBounds).
import type { WorldPoint } from './worldEditorTypes'

/** Tolerance for the orientation sign tests below — absorbs float noise on world-scale coordinates
 *  without changing any decision on non-degenerate input. */
const EPS = 1e-9

/** Signed cross product of (a→b) × (a→c): >0 left turn, <0 right turn, ≈0 collinear. */
function cross(a: WorldPoint, b: WorldPoint, c: WorldPoint): number {
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

/** True iff `p` (already known collinear with a–b) lies ON the closed segment a–b. */
function onSegment(p: WorldPoint, a: WorldPoint, b: WorldPoint): boolean {
  return (
    p.x >= Math.min(a.x, b.x) - EPS &&
    p.x <= Math.max(a.x, b.x) + EPS &&
    p.y >= Math.min(a.y, b.y) - EPS &&
    p.y <= Math.max(a.y, b.y) + EPS
  )
}

/** True iff `p` (already known collinear with a–b) lies STRICTLY inside the open segment a–b
 *  (i.e. on it but not at either endpoint). */
function strictlyInsideSegment(p: WorldPoint, a: WorldPoint, b: WorldPoint): boolean {
  if (!onSegment(p, a, b)) return false
  const atA = Math.abs(p.x - a.x) <= EPS && Math.abs(p.y - a.y) <= EPS
  const atB = Math.abs(p.x - b.x) <= EPS && Math.abs(p.y - b.y) <= EPS
  return !atA && !atB
}

/** True iff segment a–b PROPERLY intersects segment c–d: they cross at a point interior to both
 *  (strict orientation test), OR an endpoint of one lies strictly inside the other (a T-touch), OR
 *  they are collinear and overlap in more than a single shared endpoint. A mere endpoint-to-endpoint
 *  touch is NOT proper (that is how adjacent polygon edges legitimately meet). Pure decision — no
 *  clamping, no throwing. */
export function segmentsProperlyIntersect(
  a: WorldPoint,
  b: WorldPoint,
  c: WorldPoint,
  d: WorldPoint,
): boolean {
  const d1 = cross(c, d, a)
  const d2 = cross(c, d, b)
  const d3 = cross(a, b, c)
  const d4 = cross(a, b, d)

  // Strict crossing: the endpoints of each segment are on opposite sides of the other's line.
  if (
    ((d1 > EPS && d2 < -EPS) || (d1 < -EPS && d2 > EPS)) &&
    ((d3 > EPS && d4 < -EPS) || (d3 < -EPS && d4 > EPS))
  ) {
    return true
  }

  // Collinear special case: all four points on one line — proper iff the closed segments overlap in
  // more than a single point (endpoint-to-endpoint touch stays legitimate).
  if (Math.abs(d1) <= EPS && Math.abs(d2) <= EPS && Math.abs(d3) <= EPS && Math.abs(d4) <= EPS) {
    // Project onto the dominant axis to compare 1-D intervals without dividing.
    const useX = Math.abs(b.x - a.x) + Math.abs(d.x - c.x) >= Math.abs(b.y - a.y) + Math.abs(d.y - c.y)
    const [a1, a2] = useX ? [a.x, b.x] : [a.y, b.y]
    const [b1, b2] = useX ? [c.x, d.x] : [c.y, d.y]
    const lo = Math.max(Math.min(a1, a2), Math.min(b1, b2))
    const hi = Math.min(Math.max(a1, a2), Math.max(b1, b2))
    return hi - lo > EPS
  }

  // T-touch: one endpoint collinear with — and strictly inside — the other segment.
  if (Math.abs(d1) <= EPS && strictlyInsideSegment(a, c, d)) return true
  if (Math.abs(d2) <= EPS && strictlyInsideSegment(b, c, d)) return true
  if (Math.abs(d3) <= EPS && strictlyInsideSegment(c, a, b)) return true
  if (Math.abs(d4) <= EPS && strictlyInsideSegment(d, a, b)) return true

  return false
}

/** True iff the CLOSED polygon over `vertices` (edge i → i+1, wrapping) self-intersects: any pair of
 *  NON-ADJACENT edges properly intersects. Adjacent edges (sharing a vertex, including the last↔first
 *  wrap pair) are skipped — their shared endpoint is how a polygon is built, not a defect. O(n²) over
 *  the edges — authoring-scale rings (tens of vertices), not a spatial index. <3 vertices → false
 *  (not a polygon; area/vertex-count validation is a separate concern). */
export function polygonSelfIntersects(vertices: readonly WorldPoint[]): boolean {
  const n = vertices.length
  if (n < 4) return false // triangle or less: no non-adjacent edge pairs exist
  for (let i = 0; i < n; i++) {
    for (let j = i + 1; j < n; j++) {
      // Skip adjacent edge pairs: consecutive indices, and the wrap pair (first edge, last edge).
      if (j === i + 1) continue
      if (i === 0 && j === n - 1) continue
      const a = vertices[i]
      const b = vertices[(i + 1) % n]
      const c = vertices[j]
      const d = vertices[(j + 1) % n]
      if (segmentsProperlyIntersect(a, b, c, d)) return true
    }
  }
  return false
}

/** True iff `p` is inside (or ON the boundary of) the closed polygon over `vertices` — ray-cast with
 *  an explicit boundary-inclusive pre-pass so edges/vertices answer deterministically (a point on the
 *  zone border IS in the zone). <3 vertices → false (no interior exists). */
export function pointInPolygon(p: WorldPoint, vertices: readonly WorldPoint[]): boolean {
  const n = vertices.length
  if (n < 3) return false

  // Boundary pre-pass: on any closed edge → inside (deterministic on-edge answer).
  for (let i = 0; i < n; i++) {
    const a = vertices[i]
    const b = vertices[(i + 1) % n]
    if (Math.abs(cross(a, b, p)) <= EPS * Math.max(1, Math.abs(b.x - a.x) + Math.abs(b.y - a.y)) && onSegment(p, a, b)) {
      return true
    }
  }

  // Standard even-odd ray cast (horizontal ray toward +x).
  let inside = false
  for (let i = 0, j = n - 1; i < n; j = i++) {
    const a = vertices[i]
    const b = vertices[j]
    if (a.y > p.y !== b.y > p.y) {
      const xCross = a.x + ((p.y - a.y) / (b.y - a.y)) * (b.x - a.x)
      if (p.x < xCross) inside = !inside
    }
  }
  return inside
}

/** True iff `p` is inside (or ON the boundary of) the circle — squared-distance test, no sqrt. */
export function pointInCircle(p: WorldPoint, center: WorldPoint, radius: number): boolean {
  const dx = p.x - center.x
  const dy = p.y - center.y
  return dx * dx + dy * dy <= radius * radius
}

/** ABSOLUTE area of the closed polygon over `vertices` (shoelace) — orientation-independent, so a
 *  clockwise and a counter-clockwise ring of the same shape answer identically. Collinear/degenerate
 *  rings answer ≈0 (the caller's "too thin to be a zone" rejection input). <3 vertices → 0. */
export function polygonArea(vertices: readonly WorldPoint[]): number {
  const n = vertices.length
  if (n < 3) return 0
  let twice = 0
  for (let i = 0; i < n; i++) {
    const a = vertices[i]
    const b = vertices[(i + 1) % n]
    twice += a.x * b.y - b.x * a.y
  }
  return Math.abs(twice) / 2
}

/** The axis-aligned world-space bounding box of a circle (center ± radius on both axes) — the same
 *  four-corner frame representationWorldPoints feeds the camera fit. */
export function circleBbox(
  center: WorldPoint,
  radius: number,
): { minX: number; minY: number; maxX: number; maxY: number } {
  return {
    minX: center.x - radius,
    minY: center.y - radius,
    maxX: center.x + radius,
    maxY: center.y + radius,
  }
}

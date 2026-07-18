// PIRATE INTERCEPT (prototype) — pure geometry: turn an ordered ring of vertices into a SMOOTH closed
// SVG path (Catmull-Rom → cubic Bezier), so an owner-drawn polygon (or a seeded circle's vertex ring)
// reads as an organic "slime-like" blob rather than a jagged polygon. No React/DOM — reused by both
// the map's zone-rendering layer and the draw-editor's live preview (ONE smoothing authority).
//
// STANDARD Catmull-Rom → Bezier construction (closed loop, modulo indexing): for the segment
// P[i] -> P[i+1], the two Bezier control points are
//   cp1 = P[i]   + (P[i+1] - P[i-1]) / 6
//   cp2 = P[i+1] - (P[i+2] - P[i])   / 6
// which reproduces the classic Catmull-Rom tangent (tension 0) at every vertex, so the curve passes
// THROUGH every input point (unlike a Bezier fit, which would only approximate them) while reading as
// a smooth, rounded outline instead of straight polygon edges.

export interface Point2D {
  x: number
  y: number
}

/** Builds a smooth CLOSED SVG path `d` string through every point in `ring` (Catmull-Rom → Bezier).
 *  <3 finite points → null (not a polygon at all — the caller draws nothing rather than guessing a
 *  shape). Non-finite points are rejected the same way (fail closed, the movementInterpolation law). */
export function smoothClosedPathD(ring: readonly Point2D[]): string | null {
  const pts = ring.filter((p) => Number.isFinite(p.x) && Number.isFinite(p.y))
  const n = pts.length
  if (n < 3) return null

  const at = (i: number): Point2D => pts[((i % n) + n) % n]
  let d = `M ${at(0).x} ${at(0).y} `
  for (let i = 0; i < n; i++) {
    const p0 = at(i - 1)
    const p1 = at(i)
    const p2 = at(i + 1)
    const p3 = at(i + 2)
    const cp1x = p1.x + (p2.x - p0.x) / 6
    const cp1y = p1.y + (p2.y - p0.y) / 6
    const cp2x = p2.x - (p3.x - p1.x) / 6
    const cp2y = p2.y - (p3.y - p1.y) / 6
    d += `C ${cp1x} ${cp1y}, ${cp2x} ${cp2y}, ${p2.x} ${p2.y} `
  }
  return `${d}Z`
}

/** Builds a plain straight-edge closed path `d` string (the editor's in-progress preview, BEFORE a
 *  3rd point makes smoothing meaningful, and the polyline rendered while the player is still adding
 *  vertices — smoothing an incomplete shape would visually lie about the saved result). */
export function straightClosedPathD(ring: readonly Point2D[]): string | null {
  const pts = ring.filter((p) => Number.isFinite(p.x) && Number.isFinite(p.y))
  if (pts.length < 2) return null
  return `M ${pts.map((p) => `${p.x} ${p.y}`).join(' L ')} Z`
}

/** The centroid (simple average) of a ring's vertices — used to size/place the "ambush point" preview
 *  and the draw-editor's detour suggestion. NOT the polygon's true area-weighted centroid (a prototype
 *  simplification, fine for a roughly-convex owner-drawn blob or a seeded circle). */
export function ringCentroid(ring: readonly Point2D[]): Point2D | null {
  const pts = ring.filter((p) => Number.isFinite(p.x) && Number.isFinite(p.y))
  if (pts.length === 0) return null
  const sum = pts.reduce((acc, p) => ({ x: acc.x + p.x, y: acc.y + p.y }), { x: 0, y: 0 })
  return { x: sum.x / pts.length, y: sum.y / pts.length }
}

/** The largest centroid-to-vertex distance — a rough "radius" for a possibly-irregular ring, used only
 *  for the client-side detour suggestion's offset distance (never for real containment — that is
 *  `routeGeometry.ts`'s segmentIntersectsRing, mirroring the server's exact ST_Intersects). */
export function ringApproxRadius(ring: readonly Point2D[], centroid: Point2D): number {
  let max = 0
  for (const p of ring) {
    if (!Number.isFinite(p.x) || !Number.isFinite(p.y)) continue
    const d = Math.hypot(p.x - centroid.x, p.y - centroid.y)
    if (d > max) max = d
  }
  return max
}

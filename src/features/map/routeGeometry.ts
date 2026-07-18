// PIRATE INTERCEPT (prototype) — the CLIENT-SIDE half of the segment-vs-polygon crossing test, for
// the route-planner's instant visual warning (a zone flashes red while you drag/tap a point that
// would cross it) BEFORE the round trip to pirate_intercept_preview_route confirms it server-side.
// Mirrors PostGIS ST_Intersects for a SIMPLE (non-self-intersecting) polygon ring: a segment crosses
// the ring iff either endpoint is INSIDE it (ray-casting point-in-polygon) or the segment properly
// intersects any one of its edges. This is a DISPLAY-ONLY mirror — the SERVER'S
// pirate_intercept_leg_zone_hits (PostGIS) is the authority for the real risk roll; this module never
// decides gameplay, only whether to flash a warning before the player confirms.
//
// COMPOSE, DON'T FORK: reuses no other module's distance math (this is containment, not distance) —
// the SAME "pure geometry, fail closed on non-finite input" law as movementInterpolation.ts /
// territoryAt.ts governs every function here.
import type { Point2D } from './smoothPolygon'

const finite = (p: Point2D): boolean => Number.isFinite(p.x) && Number.isFinite(p.y)

/** Ray-casting point-in-polygon (even-odd rule) — the standard O(n) test. Non-finite point/ring
 *  point → false (fail closed: never claim containment on bad data). */
export function pointInRing(point: Point2D, ring: readonly Point2D[]): boolean {
  if (!finite(point) || ring.length < 3) return false
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const pi = ring[i]
    const pj = ring[j]
    if (!finite(pi) || !finite(pj)) continue
    const intersects =
      pi.y > point.y !== pj.y > point.y &&
      point.x < ((pj.x - pi.x) * (point.y - pi.y)) / (pj.y - pi.y) + pi.x
    if (intersects) inside = !inside
  }
  return inside
}

/** True iff segments (a,b) and (c,d) properly intersect (standard orientation/cross-product test;
 *  collinear-overlap is treated as NOT intersecting — a razor-thin edge-graze is exactly the kind of
 *  case the server's exposure_fraction floor exists for, not this display-only pre-check). */
function segmentsIntersect(a: Point2D, b: Point2D, c: Point2D, d: Point2D): boolean {
  const cross = (o: Point2D, p: Point2D, q: Point2D) => (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
  const d1 = cross(c, d, a)
  const d2 = cross(c, d, b)
  const d3 = cross(a, b, c)
  const d4 = cross(a, b, d)
  return (d1 > 0 !== d2 > 0) && (d3 > 0 !== d4 > 0)
}

/** True iff the leg segment (origin -> target) crosses the ring — either endpoint lands inside it, or
 *  the leg properly crosses one of its boundary edges. Fails closed (false) on non-finite input or a
 *  degenerate (<3-vertex) ring. */
export function segmentIntersectsRing(origin: Point2D, target: Point2D, ring: readonly Point2D[]): boolean {
  if (!finite(origin) || !finite(target) || ring.length < 3) return false
  if (pointInRing(origin, ring) || pointInRing(target, ring)) return true
  for (let i = 0; i < ring.length; i++) {
    const a = ring[i]
    const b = ring[(i + 1) % ring.length]
    if (!finite(a) || !finite(b)) continue
    if (segmentsIntersect(origin, target, a, b)) return true
  }
  return false
}

/**
 * PROTOTYPE-LEVEL "go around" suggestion for a weak fleet (task: "a simple perpendicular offset
 * around the zone" is fine). Offsets the segment's MIDPOINT perpendicular to the origin->target
 * direction, away from the zone centroid, far enough to clear the zone's approximate radius (plus a
 * margin). This is a SUGGESTED waypoint, not a guaranteed miss for an irregular/concave shape — the
 * player still sees the real crossing warning (from the exact ring test above) if the suggestion
 * doesn't fully clear a non-convex blob, and can drag/re-tap. Returns null on degenerate input
 * (zero-length leg, non-finite centroid) rather than emitting a garbage point.
 */
export function suggestDetourWaypoint(
  origin: Point2D,
  target: Point2D,
  zoneCentroid: Point2D,
  zoneApproxRadius: number,
  marginWorldUnits = 15,
): Point2D | null {
  if (!finite(origin) || !finite(target) || !finite(zoneCentroid)) return null
  const dx = target.x - origin.x
  const dy = target.y - origin.y
  const len = Math.hypot(dx, dy)
  if (len === 0) return null
  // unit perpendicular to the leg direction
  const px = -dy / len
  const py = dx / len
  const mid = { x: (origin.x + target.x) / 2, y: (origin.y + target.y) / 2 }
  // pick the perpendicular direction that points AWAY from the zone's centroid (the side that clears it).
  const toCenter = { x: zoneCentroid.x - mid.x, y: zoneCentroid.y - mid.y }
  const sign = px * toCenter.x + py * toCenter.y > 0 ? -1 : 1
  const offset = zoneApproxRadius + marginWorldUnits
  return { x: mid.x + sign * px * offset, y: mid.y + sign * py * offset }
}

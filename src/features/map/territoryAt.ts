// S2 TERRITORY — the ONE pure "which territory contains this point?" resolver. Lives beside
// movementInterpolation.ts by the same law that put the interpolation there: pure display math,
// shared by every consumer instead of re-derived per call site. Today the parked-fleet orbit badge
// (teamMarkers.ts) feeds it the fleet's own space_x/space_y; an in-flight consumer feeds the point
// interpolateMovementPoint returns — SAME function, never a second containment test.
//
// COMPOSE, DON'T FORK: the Euclidean distance is the ONE client helper `distance()`
// (src/game/movement/travelPreview.ts) — this module writes NO second distance formula. A future
// SERVER territory check composes public.osn_distance (0099) + territory_radius — never a third.
import { distance } from '../../game/movement/travelPreview'

/** The fields containment reads — any MapLocation satisfies this (mapTypes.ts). */
export interface TerritoryLocation {
  id: string
  x: number
  y: number
  territory_radius: number | null
}

/**
 * The territory containing `point`, or null. WORLD coordinates on both sides. Containment is
 * INCLUSIVE (dist <= radius — a fleet parked exactly on the boundary reads as inside). Overlaps
 * resolve to the NEAREST CENTER (the location the point is actually closest to — the 0220 retune
 * makes territories pairwise disjoint, so on the real map at most one ring ever contains a point
 * and this rule is belt-and-braces for any future overlap); equal distances tie-break to the
 * SMALLEST radius (the most specific territory), then deterministically to the lowest location id
 * (stable across re-renders). A NULL / non-positive / non-finite radius never contains; a
 * non-finite point is contained by nothing — fail closed, never a guessed territory (the
 * movementInterpolation law).
 * SERVER NOTE: fleet_in_territory (0218) keeps its smallest-radius-then-id order — with the
 * disjoint 0220 radii both orders answer identically on every real point; nearest-center here only
 * matters if an overlap ever returns, and then it names the site the fleet is actually at.
 */
export function territoryAt<L extends TerritoryLocation>(
  point: { x: number; y: number },
  locations: readonly L[],
): L | null {
  if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) return null
  let best: L | null = null
  let bestD = Infinity
  let bestR = Infinity
  for (const loc of locations) {
    const r = loc.territory_radius
    if (r == null || !Number.isFinite(r) || r <= 0) continue
    if (!Number.isFinite(loc.x) || !Number.isFinite(loc.y)) continue
    const d = distance(point.x, point.y, loc.x, loc.y)
    if (d > r) continue
    if (best === null || d < bestD || (d === bestD && (r < bestR || (r === bestR && loc.id < best.id)))) {
      best = loc
      bestD = d
      bestR = r
    }
  }
  return best
}

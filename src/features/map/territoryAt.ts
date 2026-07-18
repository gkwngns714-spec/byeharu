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
 * resolve to the SMALLEST containing radius (the most specific territory); equal radii tie-break
 * deterministically to the lowest location id (stable across re-renders). A NULL / non-positive /
 * non-finite radius never contains; a non-finite point is contained by nothing — fail closed,
 * never a guessed territory (the movementInterpolation law).
 */
export function territoryAt<L extends TerritoryLocation>(
  point: { x: number; y: number },
  locations: readonly L[],
): L | null {
  if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) return null
  let best: L | null = null
  let bestR = Infinity
  for (const loc of locations) {
    const r = loc.territory_radius
    if (r == null || !Number.isFinite(r) || r <= 0) continue
    if (!Number.isFinite(loc.x) || !Number.isFinite(loc.y)) continue
    if (distance(point.x, point.y, loc.x, loc.y) > r) continue
    if (best === null || r < bestR || (r === bestR && loc.id < best.id)) {
      best = loc
      bestR = r
    }
  }
  return best
}

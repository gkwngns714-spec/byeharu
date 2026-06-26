import { resolveMainShipMarker, type MarkerInputs } from './resolveMainShipMarker'

// OSN-3 S6B-ROUTE (+ OSN-HUB-1A) — the SINGLE, pure, read-only authority for whether an ACTIVE coordinate
// route may be drawn, and with what endpoints. It does NOT re-interpret movement state: it defers entirely to
// `resolveMainShipMarker` (the established marker/state resolver) for coordinate-transit coherence, then
// applies a target-kind domain policy:
//
//     target_kind === 'space'     → an arbitrary committed open-space coordinate (geometry + timestamps only).
//     target_kind === 'location'  → a named-location (port/city) destination — renders ONLY when its
//                                    target_location_id is VISIBLE in the public get_world_map() result the
//                                    client holds; a hidden/unknown destination FAILS CLOSED (null: no route,
//                                    no id/coord/name leak). Carries `destinationLocationId` so the view can
//                                    safely resolve a name for a publicly-visible destination.
//     target_kind === 'base'/other → no presentation (a coordinate Return is not an authorized feature).
//
// 'base'/unknown fail closed. A location route is dark-by-data in production today (the flag is off and the
// only anchored locations are HIDDEN starter ports, which are absent from the public map → never rendered).
//
// The route is semantically an active OUTBOUND movement to a committed destination. There is intentionally no
// `state`/`returning`/`targetKind` in the render model — only the geometry + timestamps the view needs, plus
// the optional public destination identity.
//
// PURE: no React/SVG/DOM/fetch/state/writes. No clamping. No new state machine. Timestamps pass through
// verbatim for the view to format a display-only ETA (never an arrival).

export interface ActiveSpaceRoute {
  /** committed coordinate-movement origin, in WORLD coordinates (open-space fixed domain). */
  origin: { x: number; y: number }
  /** committed coordinate-movement target, in WORLD coordinates (open-space fixed domain). */
  target: { x: number; y: number }
  /** persisted route timestamps (server truth); the view derives a display-only ETA, never an arrival. */
  departAt: string
  arriveAt: string
  /**
   * OSN-HUB-1A: for a named-location target (target_kind='location'), the destination location id — present
   * ONLY when that location is VISIBLE in the public get_world_map() result the client holds. Absent for a
   * raw open-space ('space') target. A hidden/unknown destination never produces a route at all (fail closed),
   * so this id can only ever reference a publicly-visible location — the view may safely resolve its name.
   */
  destinationLocationId?: string
}

const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)

/**
 * Returns the active coordinate-route render model, or `null`. The route exists IFF:
 *  - the main-ship marker resolver classifies the ship as `open_space_fixed` coordinate transit; AND
 *  - the backing active coordinate movement has `status === 'moving'`; AND
 *  - `target_kind === 'space'` (the only kind the deployed writer produces — fail closed otherwise); AND
 *  - origin and target coordinate pairs are finite and complete.
 * Everything else (legacy_dynamic markers, parked in_space, home, present, destroyed, terminal/mismatched/
 * malformed/missing movement, and any non-`space` / unknown target_kind) → `null`.
 */
export function resolveActiveSpaceRoute(inputs: MarkerInputs, nowMs: number): ActiveSpaceRoute | null {
  const marker = resolveMainShipMarker(inputs, nowMs)
  if (!marker) return null
  // Coordinate-space provenance gate: only the fixed open-space domain in active transit may draw a route.
  if (marker.coordinateSpace !== 'open_space_fixed') return null
  if (marker.state !== 'outbound' && marker.state !== 'returning') return null

  const mv = inputs.spaceMovement
  if (!mv || mv.status !== 'moving') return null
  if (!finite(mv.origin_x) || !finite(mv.origin_y) || !finite(mv.target_x) || !finite(mv.target_y)) return null

  const geom = {
    origin: { x: mv.origin_x, y: mv.origin_y },
    target: { x: mv.target_x, y: mv.target_y },
    departAt: mv.depart_at,
    arriveAt: mv.arrive_at,
  }

  // 'space' — an arbitrary committed open-space coordinate (the deployed writer's original kind). Geometry +
  // timestamps only (no destination identity).
  if (mv.target_kind === 'space') return geom

  // OSN-HUB-1A 'location' — a named-location (port/city) destination. It renders ONLY when its
  // target_location_id is a destination that is VISIBLE in the public map the client holds. A hidden/unknown
  // destination (e.g. a dark starter port absent from get_world_map) FAILS CLOSED → null: no route line, no
  // destination marker, and no id/coord/name leak through the render model.
  if (mv.target_kind === 'location') {
    const id = mv.target_location_id
    if (!id) return null
    if (!inputs.locations.some((l) => l.id === id)) return null
    return { ...geom, destinationLocationId: id }
  }

  // 'base' (a coordinate Return — not an authorized feature) / unknown → no presentation.
  return null
}

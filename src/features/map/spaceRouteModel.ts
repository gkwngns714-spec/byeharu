import { resolveMainShipMarker, type MarkerInputs } from './resolveMainShipMarker'

// OSN-3 S6B-ROUTE — the SINGLE, pure, read-only authority for whether an ACTIVE coordinate route may be
// drawn, and with what endpoints. It does NOT re-interpret movement state: it defers entirely to
// `resolveMainShipMarker` (the established marker/state resolver) for coordinate-transit coherence, then
// applies ONE additional domain restriction — the route renders only for the single coordinate movement
// kind the deployed writer actually produces:
//
//     target_kind === 'space'   (an arbitrary committed open-space coordinate)
//
// The only writer of main_ship_space_movements (mainship_space_begin_move) hardcodes target_kind='space';
// 'location' (future docking) and 'base' (a coordinate Return — NOT an authorized feature) are never
// produced today and have no S6B-ROUTE presentation. This model therefore FAILS CLOSED for every other
// target_kind. A future location-docking route is a separate product + visual contract; do not infer it
// from defensive backend support.
//
// The route is semantically ONE thing: an active OUTBOUND movement to a committed arbitrary open-space
// coordinate. There is intentionally no `state`/`returning`/`targetKind` in the render model — it carries
// only the geometry + timestamps the view needs.
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
  // Domain restriction (S6B-ROUTE): render ONLY the one kind the writer produces. 'location'/'base'/unknown
  // fail closed here — a docking or base-directed coordinate route is not an authorized presentation.
  if (mv.target_kind !== 'space') return null
  if (!finite(mv.origin_x) || !finite(mv.origin_y) || !finite(mv.target_x) || !finite(mv.target_y)) return null

  return {
    origin: { x: mv.origin_x, y: mv.origin_y },
    target: { x: mv.target_x, y: mv.target_y },
    departAt: mv.depart_at,
    arriveAt: mv.arrive_at,
  }
}

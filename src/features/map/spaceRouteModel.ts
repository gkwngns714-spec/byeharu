import { resolveMainShipMarker, type MarkerInputs } from './resolveMainShipMarker'

// OSN-3 S6B-ROUTE — the SINGLE, pure, read-only authority for whether an ACTIVE coordinate route may be
// drawn, and with what endpoints. It does NOT re-interpret movement state: it defers entirely to
// `resolveMainShipMarker` (the established marker/state resolver) and only produces a route model when that
// resolver has classified the ship as an `open_space_fixed` coordinate transit (outbound/returning). This
// guarantees the route line can never disagree with the ship marker, and can never appear for home,
// named-location presence, parked open space, legacy fleet movement, destroyed, terminal/mismatched/
// contradictory/incomplete/NaN movement data — every one of those returns `null` from the marker resolver
// (or a non-`open_space_fixed` marker), so it returns `null` here too.
//
// PURE: no React/SVG/DOM/fetch/state/writes. No clamping. No new state machine. Timestamps are passed
// through verbatim for the view layer to format; this module performs no time math beyond what the marker
// resolver already used to classify transit.

export type ActiveSpaceRouteState = 'outbound' | 'returning'

export interface ActiveSpaceRoute {
  /** committed coordinate-movement origin, in WORLD coordinates (open-space fixed domain). */
  origin: { x: number; y: number }
  /** committed coordinate-movement target, in WORLD coordinates (open-space fixed domain). */
  target: { x: number; y: number }
  /** outbound (target_kind !== 'base') vs returning (target_kind === 'base'); mirrors the marker resolver. */
  state: ActiveSpaceRouteState
  /** the committed movement's target_kind, passed through for the view (no new semantics derived here). */
  targetKind: string
  /** persisted route timestamps (server truth); the view derives a display-only ETA, never an arrival. */
  departAt: string
  arriveAt: string
}

const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)

/**
 * Returns the active coordinate-route render model, or `null`. The route exists IFF the main-ship marker
 * resolver classifies the ship as an `open_space_fixed` coordinate transit (state outbound/returning) AND
 * the backing active coordinate movement carries finite, complete origin/target pairs. Everything else
 * (legacy_dynamic markers, parked in_space, home, present, destroyed, malformed, missing) → `null`.
 */
export function resolveActiveSpaceRoute(inputs: MarkerInputs, nowMs: number): ActiveSpaceRoute | null {
  const marker = resolveMainShipMarker(inputs, nowMs)
  if (!marker) return null
  // Coordinate-space provenance is the gate: only the fixed open-space domain may draw a coordinate route.
  if (marker.coordinateSpace !== 'open_space_fixed') return null
  if (marker.state !== 'outbound' && marker.state !== 'returning') return null

  // For an open_space_fixed outbound/returning marker the resolver has already validated the active
  // coordinate movement end-to-end; re-narrow + re-check finiteness here so the route model is provably
  // complete on its own (a forgotten field is a type error, not a silent half-drawn line).
  const mv = inputs.spaceMovement
  if (!mv || mv.status !== 'moving') return null
  if (!finite(mv.origin_x) || !finite(mv.origin_y) || !finite(mv.target_x) || !finite(mv.target_y)) return null

  return {
    origin: { x: mv.origin_x, y: mv.origin_y },
    target: { x: mv.target_x, y: mv.target_y },
    state: marker.state,
    targetKind: mv.target_kind,
    departAt: mv.depart_at,
    arriveAt: mv.arrive_at,
  }
}

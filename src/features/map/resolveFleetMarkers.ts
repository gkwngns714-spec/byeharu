import { interpolateMovementPoint } from './movementInterpolation'
import type { FleetPosition } from './mainshipApi'
import type { MapLocation } from './mapTypes'

// FLEETMAP — the pure, read-only resolver that turns the server fleet-positions projection into one map
// marker per PLACEABLE owned ship. It never invents a position: it trusts the server-decided `place` and
// reuses the ONE shared movement lerp (interpolateMovementPoint) for transit — the same helper the single-ship
// resolver and the team markers use (no second interpolation copy). No React/SVG/fetch/writes.
//
//   • transit  → interpolate the committed segment (target_kind='base' → returning, else outbound);
//   • in_space → the ship-owned coordinates (finite-guarded);
//   • docked   → the port's coordinates, looked up from the visible world locations (fail closed if absent);
//   • hidden / anything incoherent → NO marker (mirrors resolveMainShipMarker returning null).
//
// The `selected` flag marks the shell-selected ship so the layer can highlight it; every other owned ship is
// still returned (subdued in the layer). This is what fixes the bug where owning 2+ ships hid the whole fleet.

export type FleetMarkerState = 'docked' | 'outbound' | 'returning' | 'in_space'

export interface FleetMarker {
  main_ship_id: string
  name: string
  /** WORLD coordinates — project through the map's `norm` exactly like every other marker layer. */
  x: number
  y: number
  state: FleetMarkerState
  /** True for the shell-selected ship (drives the distinct highlight in the layer). */
  selected: boolean
}

const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)

const EMPTY_EXCLUDE: ReadonlySet<string> = new Set()

export function resolveFleetMarkers(
  positions: readonly FleetPosition[],
  locations: readonly Pick<MapLocation, 'id' | 'x' | 'y'>[],
  selectedShipId: string | null,
  nowMs: number,
  // FLEETMAP de-dup: ship ids ALREADY drawn by a TEAM marker (a dock badge or an in-flight moving badge).
  // Such a ship is skipped here so it is NOT double-drawn as a redundant chevron beneath its team badge —
  // the SAME exclusion posture as the selected ship (whose glyph is owned by the single MainShipMarker).
  excludeShipIds: ReadonlySet<string> = EMPTY_EXCLUDE,
): FleetMarker[] {
  const out: FleetMarker[] = []
  for (const p of positions) {
    if (excludeShipIds.has(p.main_ship_id)) continue // a team marker already represents this ship → no redundant chevron
    let x: number | null = null
    let y: number | null = null
    let state: FleetMarkerState | null = null

    switch (p.place) {
      case 'transit': {
        if (!p.segment) break
        const pt = interpolateMovementPoint(p.segment, nowMs)
        if (!pt) break // incoherent segment → no marker (never a guessed point)
        x = pt.x
        y = pt.y
        state = p.segment.target_kind === 'base' ? 'returning' : 'outbound'
        break
      }
      case 'in_space': {
        if (!finite(p.space_x) || !finite(p.space_y)) break
        x = p.space_x
        y = p.space_y
        state = 'in_space'
        break
      }
      case 'docked': {
        const loc = locations.find((l) => l.id === p.location_id)
        if (!loc || !finite(loc.x) || !finite(loc.y)) break // port not in the visible world → no marker
        x = loc.x
        y = loc.y
        state = 'docked'
        break
      }
      // 'hidden' (home / incoherent / destroyed) → no marker.
    }

    if (x === null || y === null || state === null) continue
    out.push({
      main_ship_id: p.main_ship_id,
      name: p.name,
      x,
      y,
      state,
      selected: !!selectedShipId && p.main_ship_id === selectedShipId,
    })
  }
  return out
}

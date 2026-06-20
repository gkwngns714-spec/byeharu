import type { MainShipLite } from './useGalaxyMapData'
import type { MainShipFleet } from './mainshipApi'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { MapLocation } from './mapTypes'

// OSN-1 — pure, read-only resolver for the main ship's DISPLAY position. This is the SINGLE place
// that derives main-ship map position. It returns a normalized, multi-entity-capable view-model in
// WORLD coordinates (the map applies its own world→viewBox normalization), or `null` when there is
// no *authoritative* position. No React, no SVG, no fetch, no writes — purely a function of the
// already-loaded data + a caller-supplied clock (`nowMs`), so it is deterministic and testable.
//
// Truthfulness rule (OSN-1): never show a false position. While in flight (moving/returning) the
// marker MUST come from a usable movement row or it is hidden; it never falls back to home/location
// mid-flight. Static home/present positions are used ONLY when that is the genuine authoritative state.

export type MainShipMarkerState = 'home' | 'present' | 'outbound' | 'returning'

export interface ShipMarker {
  entityId: string
  entityType: 'main_ship' // multi-entity-capable shape; OSN-1 only ever emits the local self marker
  relation: 'self'
  x: number // WORLD coordinate
  y: number // WORLD coordinate
  state: MainShipMarkerState
}

export interface MarkerInputs {
  mainShip: Pick<MainShipLite, 'main_ship_id' | 'status'> | null
  mainShipFleet: MainShipFleet | null
  movements: FleetMovement[]
  base: { x: number; y: number } | null
  locations: Pick<MapLocation, 'id' | 'x' | 'y'>[]
}

const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)

export function resolveMainShipMarker(inp: MarkerInputs, nowMs: number): ShipMarker | null {
  const { mainShip, mainShipFleet: fleet, movements, base, locations } = inp
  if (!mainShip) return null
  const make = (state: MainShipMarkerState, x: number, y: number): ShipMarker => ({
    entityId: mainShip.main_ship_id,
    entityType: 'main_ship',
    relation: 'self',
    x,
    y,
    state,
  })

  // Destroyed → hide (no authoritative coordinate in OSN-1; a free-space last-known is OSN-2).
  if (mainShip.status === 'destroyed') return null

  // In-flight (moving / returning): interpolate from a usable movement row ONLY, else hide.
  // Never fall back to home/location while in flight — that would teleport the marker.
  if (fleet && (fleet.status === 'moving' || fleet.status === 'returning')) {
    const mv = movements.find((m) => m.fleet_id === fleet.id && m.status === 'moving')
    if (!mv) return null
    const dep = Date.parse(mv.depart_at)
    const arr = Date.parse(mv.arrive_at)
    if (!finite(dep) || !finite(arr) || arr <= dep) return null
    if (!finite(mv.origin_x) || !finite(mv.origin_y) || !finite(mv.target_x) || !finite(mv.target_y)) return null
    const t = Math.max(0, Math.min(1, (nowMs - dep) / (arr - dep))) // clamp progress to 0..1
    const x = mv.origin_x + t * (mv.target_x - mv.origin_x)
    const y = mv.origin_y + t * (mv.target_y - mv.origin_y)
    return make(mv.target_type === 'base' ? 'returning' : 'outbound', x, y)
  }

  // Present at a named location: ONLY when the current location actually resolves.
  if (fleet && fleet.status === 'present') {
    const loc = fleet.current_location_id ? locations.find((l) => l.id === fleet.current_location_id) : undefined
    if (!loc || !finite(loc.x) || !finite(loc.y)) return null
    return make('present', loc.x, loc.y)
  }

  // Genuinely home: no active fleet AND the ship row reads 'home' AND base resolves.
  if (!fleet && mainShip.status === 'home' && base && finite(base.x) && finite(base.y)) {
    return make('home', base.x, base.y)
  }

  // Anything else (e.g. a brief pre-reconciler 'traveling'/'returning' with no active fleet,
  // or idle/completed) is not an authoritative position → hide.
  return null
}

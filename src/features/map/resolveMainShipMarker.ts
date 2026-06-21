import type { MainShipLite } from './useGalaxyMapData'
import type { MainShipFleet, MainShipPresence, MainShipSpaceMovement, SpatialState } from './mainshipApi'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { MapLocation } from './mapTypes'

// OSN-1 / OSN-2b / OSN-3-S1 — the SINGLE, pure, read-only resolver for the main ship's DISPLAY
// position. Returns one WORLD-coordinate marker or `null`. It NEVER guesses, falls back, or combines
// partial state from different sources. No React/SVG/fetch/writes. OSN-3 S1 only EXTENDS this resolver
// to read the already-deployed coordinate-domain states; it adds no writer.
//
// Legacy `spatial_state IS NULL` behavior is unchanged. New non-null states are validated end-to-end
// against the fleet / coordinate-movement / presence records; any missing or contradictory condition
// returns `null`. This is a DISPLAY resolver only — NOT the future server-side authoritative origin
// resolver.

export type MainShipMarkerState = 'home' | 'present' | 'outbound' | 'returning' | 'in_space'

export interface ShipMarker {
  entityId: string
  entityType: 'main_ship'
  relation: 'self'
  x: number // WORLD coordinate
  y: number // WORLD coordinate
  state: MainShipMarkerState
}

export interface MarkerInputs {
  mainShip: Pick<MainShipLite, 'main_ship_id' | 'status' | 'spatial_state' | 'space_x' | 'space_y'> | null
  mainShipFleet: MainShipFleet | null
  movements: FleetMovement[]
  presence: MainShipPresence | null
  // OSN-3 S1: the active coordinate movement (status='moving') for this ship, or null.
  spaceMovement: MainShipSpaceMovement | null
  base: { x: number; y: number } | null
  locations: Pick<MapLocation, 'id' | 'x' | 'y'>[]
}

const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)

export function resolveMainShipMarker(inp: MarkerInputs, nowMs: number): ShipMarker | null {
  const { mainShip, mainShipFleet: fleet, movements, presence, spaceMovement, base, locations } = inp
  if (!mainShip) return null
  const make = (state: MainShipMarkerState, x: number, y: number): ShipMarker => ({
    entityId: mainShip.main_ship_id,
    entityType: 'main_ship',
    relation: 'self',
    x,
    y,
    state,
  })

  // §A — Destroyed / contradictory-destroyed → hide.
  if (mainShip.status === 'destroyed' || mainShip.spatial_state === 'destroyed') return null

  const ss: SpatialState | null = mainShip.spatial_state
  // Helpers shared across the new branches.
  const presenceActive = !!presence && presence.status === 'active'
  const coordMoving = !!spaceMovement && spaceMovement.status === 'moving'

  // §B — in_space: ship-owned coordinates only, no active-state contradiction.
  if (ss === 'in_space') {
    if (fleet) return null
    if (presenceActive) return null
    if (coordMoving) return null
    const { space_x, space_y } = mainShip
    if (!finite(space_x) || !finite(space_y)) return null
    return make('in_space', space_x, space_y)
  }

  // §C (OSN-3 S1) — in_transit: interpolate the active COORDINATE movement, only when fully coherent.
  if (ss === 'in_transit') {
    if (mainShip.status !== 'traveling') return null
    if (!fleet) return null
    if (!coordMoving || !spaceMovement) return null
    if (spaceMovement.main_ship_id !== mainShip.main_ship_id) return null
    if (spaceMovement.fleet_id !== fleet.id) return null
    if (fleet.status !== 'moving') return null
    if (fleet.location_mode !== 'movement') return null
    if (fleet.active_movement_id !== null) return null
    if (fleet.active_space_movement_id !== spaceMovement.id) return null
    if (presenceActive) return null
    const dep = Date.parse(spaceMovement.depart_at)
    const arr = Date.parse(spaceMovement.arrive_at)
    if (!finite(dep) || !finite(arr) || arr <= dep) return null
    if (!finite(spaceMovement.origin_x) || !finite(spaceMovement.origin_y) ||
        !finite(spaceMovement.target_x) || !finite(spaceMovement.target_y)) return null
    const t = Math.max(0, Math.min(1, (nowMs - dep) / (arr - dep)))
    const x = spaceMovement.origin_x + t * (spaceMovement.target_x - spaceMovement.origin_x)
    const y = spaceMovement.origin_y + t * (spaceMovement.target_y - spaceMovement.origin_y)
    return make(spaceMovement.target_kind === 'base' ? 'returning' : 'outbound', x, y)
  }

  // §D (OSN-3 S1) — at_location: validated named-location position.
  if (ss === 'at_location') {
    if (mainShip.status !== 'stationary') return null
    if (!fleet || fleet.status !== 'present') return null
    if (!fleet.current_location_id) return null
    if (fleet.active_movement_id !== null) return null
    if (fleet.active_space_movement_id !== null) return null
    if (coordMoving) return null
    if (!presence || presence.status !== 'active') return null
    if (presence.fleet_id !== fleet.id) return null
    if (presence.location_id !== fleet.current_location_id) return null
    const loc = locations.find((l) => l.id === fleet.current_location_id)
    if (!loc || !finite(loc.x) || !finite(loc.y)) return null
    return make('present', loc.x, loc.y)
  }

  // §E (OSN-3 S1) — home: authoritative base coordinates, no active state.
  if (ss === 'home') {
    if (mainShip.status !== 'home') return null
    if (fleet) return null
    if (presenceActive) return null
    if (coordMoving) return null
    if (!base || !finite(base.x) || !finite(base.y)) return null
    return make('home', base.x, base.y)
  }

  // §F — legacy (spatial_state IS NULL): unchanged derivation.
  if (ss === null) {
    // In-flight (legacy moving/returning): interpolate from a usable legacy movement row ONLY.
    if (fleet && (fleet.status === 'moving' || fleet.status === 'returning')) {
      const mv = movements.find((m) => m.fleet_id === fleet.id && m.status === 'moving')
      if (!mv) return null
      const dep = Date.parse(mv.depart_at)
      const arr = Date.parse(mv.arrive_at)
      if (!finite(dep) || !finite(arr) || arr <= dep) return null
      if (!finite(mv.origin_x) || !finite(mv.origin_y) || !finite(mv.target_x) || !finite(mv.target_y)) return null
      const t = Math.max(0, Math.min(1, (nowMs - dep) / (arr - dep)))
      const x = mv.origin_x + t * (mv.target_x - mv.origin_x)
      const y = mv.origin_y + t * (mv.target_y - mv.origin_y)
      return make(mv.target_type === 'base' ? 'returning' : 'outbound', x, y)
    }
    // Present at a named location — only when the entire named-location state is coherent.
    if (fleet && fleet.status === 'present') {
      if (!fleet.current_location_id) return null
      if (!presence || presence.status !== 'active') return null
      if (presence.fleet_id !== fleet.id) return null
      if (presence.location_id !== fleet.current_location_id) return null
      const loc = locations.find((l) => l.id === fleet.current_location_id)
      if (!loc || !finite(loc.x) || !finite(loc.y)) return null
      return make('present', loc.x, loc.y)
    }
    // Genuinely home: no active fleet AND ship 'home' AND base resolves.
    if (!fleet && mainShip.status === 'home' && base && finite(base.x) && finite(base.y)) {
      return make('home', base.x, base.y)
    }
    return null
  }

  // §G — any other / unknown / malformed spatial_state → hide safely.
  return null
}

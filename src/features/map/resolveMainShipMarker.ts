import type { MainShipLite } from './useGalaxyMapData'
import type { MainShipFleet, MainShipPresence, SpatialState } from './mainshipApi'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { MapLocation } from './mapTypes'

// OSN-1 + OSN-2b — pure, read-only resolver for the main ship's DISPLAY position. This is the SINGLE
// place that derives main-ship map position. It returns a normalized, multi-entity-capable view-model
// in WORLD coordinates (the map applies its own world→viewBox normalization), or `null` when there is
// no *authoritative* position. No React, no SVG, no fetch, no writes — purely a function of the
// already-loaded data + a caller-supplied clock (`nowMs`), so it is deterministic and testable.
//
// Truthfulness rule: never show a false position. It NEVER guesses, falls back, or combines partial
// state from different sources. While in flight (moving/returning) the marker MUST come from a usable
// movement row or it is hidden; named-location presence must be fully coherent or it is hidden.
//
// OSN-2b read-model (migration 0054 schema, no writer yet):
//   • spatial_state = 'in_space'  → ship-owned space_x/space_y are the ONLY position source.
//   • spatial_state IS NULL       → legacy: derive from fleet/movement/presence/base (unchanged).
//   • status/spatial_state 'destroyed' (or any contradiction) → null.
//   • any other (recognized-but-not-yet-rendered: home/at_location/in_transit, or unknown) → null.
// This is a DISPLAY resolver only — NOT a future server-side authoritative origin resolver.

export type MainShipMarkerState = 'home' | 'present' | 'outbound' | 'returning' | 'in_space'

export interface ShipMarker {
  entityId: string
  entityType: 'main_ship' // multi-entity-capable shape; only ever emits the local self marker
  relation: 'self'
  x: number // WORLD coordinate
  y: number // WORLD coordinate
  state: MainShipMarkerState
}

export interface MarkerInputs {
  mainShip: Pick<MainShipLite, 'main_ship_id' | 'status' | 'spatial_state' | 'space_x' | 'space_y'> | null
  mainShipFleet: MainShipFleet | null
  movements: FleetMovement[]
  // The active location-presence for the main-ship fleet (or null). Required to validate a present
  // marker — a present fleet WITHOUT a matching active presence resolves to null (no guessing).
  presence: MainShipPresence | null
  base: { x: number; y: number } | null
  locations: Pick<MapLocation, 'id' | 'x' | 'y'>[]
}

// Strict numeric check — never truthiness (0 and negatives are valid world coordinates).
const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)

export function resolveMainShipMarker(inp: MarkerInputs, nowMs: number): ShipMarker | null {
  const { mainShip, mainShipFleet: fleet, movements, presence, base, locations } = inp
  if (!mainShip) return null
  const make = (state: MainShipMarkerState, x: number, y: number): ShipMarker => ({
    entityId: mainShip.main_ship_id,
    entityType: 'main_ship',
    relation: 'self',
    x,
    y,
    state,
  })

  const ss: SpatialState | null = mainShip.spatial_state

  // §A — Destroyed or contradictory-destroyed → hide. If EITHER the ship status or the spatial_state
  // says destroyed, there is no valid live marker; never show an old location/parked coordinate.
  if (mainShip.status === 'destroyed' || ss === 'destroyed') return null

  // §B — in_space: ship-owned coordinates are the ONLY source. Hidden on any contradiction
  // (an active linked fleet or an active presence means the ship is NOT durably parked).
  if (ss === 'in_space') {
    if (fleet) return null // an active linked fleet contradicts "parked in open space"
    if (presence && presence.status === 'active') return null // active named-location presence contradicts it
    const { space_x, space_y } = mainShip
    if (!finite(space_x) || !finite(space_y)) return null // both present AND both finite (rejects NaN/±Inf, half-pairs)
    return make('in_space', space_x, space_y)
  }

  // §C — legacy (spatial_state IS NULL): derive from the live records, deterministically.
  if (ss === null) {
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

    // Present at a named location — ONLY when the ENTIRE named-location state is coherent:
    //   fleet present ∧ current_location_id set ∧ matching ACTIVE presence (same fleet, same
    //   location) ∧ that location resolves to finite coordinates. Otherwise hide (no fallback).
    if (fleet && fleet.status === 'present') {
      if (!fleet.current_location_id) return null
      if (!presence || presence.status !== 'active') return null
      if (presence.fleet_id !== fleet.id) return null
      if (presence.location_id !== fleet.current_location_id) return null
      const loc = locations.find((l) => l.id === fleet.current_location_id)
      if (!loc || !finite(loc.x) || !finite(loc.y)) return null
      return make('present', loc.x, loc.y)
    }

    // Genuinely home: no active fleet AND the ship row reads 'home' AND base resolves.
    if (!fleet && mainShip.status === 'home' && base && finite(base.x) && finite(base.y)) {
      return make('home', base.x, base.y)
    }

    // Anything else under a legacy NULL (e.g. a brief pre-reconciler 'traveling'/'returning' with no
    // active fleet, or idle/completed) is not an authoritative position → hide.
    return null
  }

  // §D — any other spatial_state (recognized-but-not-yet-rendered home/at_location/in_transit, or an
  // unknown/malformed value) has no OSN-2b display contract → hide safely. OSN-3 extends THIS resolver
  // (never a second one) when those states acquire a live writer.
  return null
}

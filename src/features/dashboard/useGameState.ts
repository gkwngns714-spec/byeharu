import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchGameConfig, fetchMainshipSendEnabled, fetchUnitTypes, type UnitType } from '../../lib/catalog'
import { fetchMyMainShip, type MainShipView } from '../map/mainshipApi'
import { fetchLocationStates, fetchWorldMap } from '../map/mapApi'
import type { LocationState, MapLocation } from '../map/mapTypes'
import { ensureBase, fetchBase, fetchBaseResources, fetchBaseUnits } from '../base/baseApi'
import type { Base, BaseResource, BaseUnit } from '../base/baseTypes'
import {
  fetchActiveMovements,
  fetchActivePresences,
  fetchFleetUnits,
  fetchFleets,
} from '../fleets/fleetApi'
import type { Fleet, FleetMovement, FleetUnit, LocationPresence } from '../fleets/fleetTypes'
import { fetchBuildOrders } from '../production/productionApi'
import type { BuildOrder } from '../production/productionTypes'

export interface GameState {
  loading: boolean
  error: string | null
  base: Base | null
  units: BaseUnit[]
  resources: BaseResource[]
  unitTypes: UnitType[]
  locations: MapLocation[]
  config: Record<string, number>
  fleets: Fleet[]
  fleetUnits: FleetUnit[]
  movements: FleetMovement[]
  presences: LocationPresence[]
  locationStates: Record<string, LocationState>
  buildOrders: BuildOrder[]
  // Phase 10H: the player's main ship (owner-read) + the master flag (read-only, for panel gating).
  // The active main-ship fleet + its movement are derived from `fleets`/`movements` in the panel.
  mainShip: MainShipView | null
  mainshipSendEnabled: boolean
}

const EMPTY: GameState = {
  loading: true,
  error: null,
  base: null,
  units: [],
  resources: [],
  unitTypes: [],
  locations: [],
  config: {},
  fleets: [],
  fleetUnits: [],
  movements: [],
  presences: [],
  locationStates: {},
  buildOrders: [],
  mainShip: null,
  mainshipSendEnabled: false,
}

/**
 * Loads + polls all owner-scoped game state for the Command Center. Static data
 * (unit catalog, world map) is fetched once; dynamic state is refreshed every 3s
 * and on demand via refresh(). Read-only — all mutations go through RPCs elsewhere.
 */
export function useGameState(pollMs = 3000) {
  const [state, setState] = useState<GameState>(EMPTY)
  const staticRef = useRef<{
    unitTypes: UnitType[]
    locations: MapLocation[]
    config: Record<string, number>
    mainshipSendEnabled: boolean
  } | null>(null)

  const load = useCallback(async () => {
    try {
      if (!staticRef.current) {
        const [unitTypes, world, config, mainshipSendEnabled] = await Promise.all([
          fetchUnitTypes(),
          fetchWorldMap(),
          fetchGameConfig(),
          fetchMainshipSendEnabled(),
        ])
        const locations = world.sectors.flatMap((s) => s.zones.flatMap((z) => z.locations))
        staticRef.current = { unitTypes, locations, config, mainshipSendEnabled }
      }

      const base = await fetchBase()
      const [units, resources, fleets, fleetUnits, movements, presences, locationStates, buildOrders, mainShip] =
        await Promise.all([
          base ? fetchBaseUnits(base.id) : Promise.resolve([]),
          base ? fetchBaseResources(base.id) : Promise.resolve([]),
          fetchFleets(),
          fetchFleetUnits(),
          fetchActiveMovements(),
          fetchActivePresences(),
          fetchLocationStates(),
          fetchBuildOrders(),
          fetchMyMainShip().catch(() => null), // non-fatal: a main-ship read hiccup must not break the Command Center
        ])

      setState({
        loading: false,
        error: null,
        base,
        units,
        resources,
        fleets,
        fleetUnits,
        movements,
        presences,
        locationStates,
        buildOrders,
        mainShip,
        mainshipSendEnabled: staticRef.current.mainshipSendEnabled,
        unitTypes: staticRef.current.unitTypes,
        locations: staticRef.current.locations,
        config: staticRef.current.config,
      })
    } catch (e) {
      setState((s) => ({ ...s, loading: false, error: e instanceof Error ? e.message : String(e) }))
    }
  }, [])

  useEffect(() => {
    let active = true
    ;(async () => {
      try {
        await ensureBase()
      } catch {
        /* non-fatal: base may already exist */
      }
      if (active) await load()
    })()
    const iv = setInterval(() => {
      if (active) void load()
    }, pollMs)
    return () => {
      active = false
      clearInterval(iv)
    }
  }, [load, pollMs])

  return { ...state, refresh: load }
}

import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchUnitTypes, type UnitType } from '../../lib/catalog'
import { fetchWorldMap } from '../map/mapApi'
import type { MapLocation } from '../map/mapTypes'
import { ensureBase, fetchBase, fetchBaseResources, fetchBaseUnits } from '../base/baseApi'
import type { Base, BaseResource, BaseUnit } from '../base/baseTypes'
import {
  fetchActiveMovements,
  fetchActivePresences,
  fetchFleetUnits,
  fetchFleets,
} from '../fleets/fleetApi'
import type { Fleet, FleetMovement, FleetUnit, LocationPresence } from '../fleets/fleetTypes'

export interface GameState {
  loading: boolean
  error: string | null
  base: Base | null
  units: BaseUnit[]
  resources: BaseResource[]
  unitTypes: UnitType[]
  locations: MapLocation[]
  fleets: Fleet[]
  fleetUnits: FleetUnit[]
  movements: FleetMovement[]
  presences: LocationPresence[]
}

const EMPTY: GameState = {
  loading: true,
  error: null,
  base: null,
  units: [],
  resources: [],
  unitTypes: [],
  locations: [],
  fleets: [],
  fleetUnits: [],
  movements: [],
  presences: [],
}

/**
 * Loads + polls all owner-scoped game state for the Command Center. Static data
 * (unit catalog, world map) is fetched once; dynamic state is refreshed every 3s
 * and on demand via refresh(). Read-only — all mutations go through RPCs elsewhere.
 */
export function useGameState(pollMs = 3000) {
  const [state, setState] = useState<GameState>(EMPTY)
  const staticRef = useRef<{ unitTypes: UnitType[]; locations: MapLocation[] } | null>(null)

  const load = useCallback(async () => {
    try {
      if (!staticRef.current) {
        const [unitTypes, world] = await Promise.all([fetchUnitTypes(), fetchWorldMap()])
        const locations = world.sectors.flatMap((s) => s.zones.flatMap((z) => z.locations))
        staticRef.current = { unitTypes, locations }
      }

      const base = await fetchBase()
      const [units, resources, fleets, fleetUnits, movements, presences] = await Promise.all([
        base ? fetchBaseUnits(base.id) : Promise.resolve([]),
        base ? fetchBaseResources(base.id) : Promise.resolve([]),
        fetchFleets(),
        fetchFleetUnits(),
        fetchActiveMovements(),
        fetchActivePresences(),
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
        unitTypes: staticRef.current.unitTypes,
        locations: staticRef.current.locations,
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

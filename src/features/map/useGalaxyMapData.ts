import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { fetchWorldMap, fetchLocationStates } from './mapApi'
import type { LocationState, MapLocation } from './mapTypes'
import { fetchBase, fetchBaseUnits } from '../base/baseApi'
import type { Base, BaseUnit } from '../base/baseTypes'
import { fetchActiveMovements } from '../fleets/fleetApi'
import type { FleetMovement } from '../fleets/fleetTypes'
import { fetchUnitTypes, fetchMainshipSendEnabled, type UnitType } from '../../lib/catalog'
import { fetchActiveMainShipFleet, type MainShipFleet } from './mainshipApi'

// Read-only galaxy-map data. Reuses existing world-map / base / movement fetchers and
// adds a tiny owner-read of main_ship_instances. NO writes, NO new backend. Static world
// structure is fetched once; dynamic movement/world-state/ship is polled.

export interface MainShipLite {
  main_ship_id: string
  name: string
  status: string
  hull_type_id: string
  hp: number
  max_hp: number
  cargo_capacity: number
}

/** Sector + zone names for a location, for the read-only detail panel. */
export interface LocationMeta {
  sectorName: string
  zoneName: string
}

export interface GalaxyMapData {
  loading: boolean
  error: string | null
  locations: MapLocation[]
  meta: Record<string, LocationMeta>
  base: Base | null
  mainShip: MainShipLite | null
  movements: FleetMovement[]
  locationStates: Record<string, LocationState>
  baseUnits: BaseUnit[]
  unitTypes: UnitType[]
  // Phase 10D: feature flag (read once) + the ship's active linked fleet (polled, for status).
  mainshipSendEnabled: boolean
  mainShipFleet: MainShipFleet | null
  refresh: () => Promise<void>
}

async function fetchMainShip(): Promise<MainShipLite | null> {
  // Owner-read RLS returns only the caller's ship (or nothing if not created yet).
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select('main_ship_id, name, status, hull_type_id, hp, max_hp, cargo_capacity')
    .maybeSingle()
  if (error) return null // non-fatal: ship is optional in Phase 9A
  return (data as MainShipLite) ?? null
}

const EMPTY: Omit<GalaxyMapData, 'refresh'> = {
  loading: true,
  error: null,
  locations: [],
  meta: {},
  base: null,
  mainShip: null,
  movements: [],
  locationStates: {},
  baseUnits: [],
  unitTypes: [],
  mainshipSendEnabled: false,
  mainShipFleet: null,
}

export function useGalaxyMapData(pollMs = 4000): GalaxyMapData {
  const [state, setState] = useState(EMPTY)
  const staticRef = useRef<{
    locations: MapLocation[]
    meta: Record<string, LocationMeta>
    base: Base | null
    unitTypes: UnitType[]
    mainshipSendEnabled: boolean
  } | null>(null)

  const load = useCallback(async () => {
    try {
      if (!staticRef.current) {
        const [world, base, unitTypes, mainshipSendEnabled] = await Promise.all([
          fetchWorldMap(), fetchBase(), fetchUnitTypes(), fetchMainshipSendEnabled(),
        ])
        const locations: MapLocation[] = []
        const meta: Record<string, LocationMeta> = {}
        for (const sector of world.sectors) {
          for (const zone of sector.zones) {
            for (const loc of zone.locations) {
              locations.push(loc)
              meta[loc.id] = { sectorName: sector.name, zoneName: zone.name }
            }
          }
        }
        staticRef.current = { locations, meta, base, unitTypes, mainshipSendEnabled }
      }

      const base = staticRef.current.base
      const [movements, locationStates, mainShip, baseUnits] = await Promise.all([
        fetchActiveMovements(),
        fetchLocationStates(),
        fetchMainShip(),
        base ? fetchBaseUnits(base.id) : Promise.resolve([]),
      ])
      // The active linked fleet (zero units) drives the live main-ship status. Only read it
      // when a ship exists; absent ship or no in-flight fleet → null (home).
      const mainShipFleet = mainShip ? await fetchActiveMainShipFleet(mainShip.main_ship_id) : null

      setState({
        loading: false,
        error: null,
        locations: staticRef.current.locations,
        meta: staticRef.current.meta,
        base,
        mainShip,
        movements,
        locationStates,
        baseUnits,
        unitTypes: staticRef.current.unitTypes,
        mainshipSendEnabled: staticRef.current.mainshipSendEnabled,
        mainShipFleet,
      })
    } catch (e) {
      setState((s) => ({ ...s, loading: false, error: e instanceof Error ? e.message : String(e) }))
    }
  }, [])

  useEffect(() => {
    let active = true
    void load()
    const iv = setInterval(() => { if (active) void load() }, pollMs)
    return () => { active = false; clearInterval(iv) }
  }, [load, pollMs])

  return { ...state, refresh: load }
}

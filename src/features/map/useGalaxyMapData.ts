import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { fetchWorldMap, fetchLocationStates } from './mapApi'
import type { LocationState, MapLocation } from './mapTypes'
import { fetchActiveMovements } from '../fleets/fleetApi'
import type { FleetMovement } from '../fleets/fleetTypes'
import { fetchMainshipSendEnabled } from '../../lib/catalog'
import {
  fetchActiveMainShipFleet, fetchHeldMainShipFleet, fetchActiveMainShipPresence, fetchActiveMainShipSpaceMovement,
  resolveOwnedShip,
  type MainShipFleet, type MainShipPresence, type MainShipSpaceMovement, type SpatialState,
} from './mainshipApi'
import { fetchMyShipGroups, fetchMyShipGroupMap, fetchMyPresentShipFleets } from '../command/teamApi'
import { deriveDockedTeamRollups, type DockedTeamRollup } from '../command/teamRollup'
import type { GroupRow } from '../command/teamRoster'
import { TEAM_COMMAND_ENABLED } from './osnReleaseGates'

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
  // OSN-2 (migration 0054). NULL on every row today (legacy). Read-only here; no writer in OSN-2b.
  spatial_state: SpatialState | null
  space_x: number | null
  space_y: number | null
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
  mainShip: MainShipLite | null
  movements: FleetMovement[]
  locationStates: Record<string, LocationState>
  // Phase 10D: feature flag (read once) + the ship's active linked fleet (polled, for status).
  mainshipSendEnabled: boolean
  mainShipFleet: MainShipFleet | null
  // Slice D1: the HELD ship's current fleet (its most-recent 'completed' fleet), read only while the
  // ship is held (spatial_state='in_space'). Addresses move_main_ship_to_location's held-departure
  // branch so a held ship can Send again. Null unless the ship is genuinely held.
  mainShipHeldFleet: MainShipFleet | null
  // OSN-2b: the active location-presence for the main-ship fleet (polled), used by the resolver to
  // validate a named-location marker. Null unless the fleet is genuinely present at a location.
  mainShipPresence: MainShipPresence | null
  // OSN-3 S1: the active coordinate movement for the main ship (polled, read-only). Null unless a
  // future coordinate move exists (no writer in S1, so always null in practice until OSN-3 S3+).
  mainShipSpaceMovement: MainShipSpaceMovement | null
  // TEAMMAP-0: the owner's teams (the REUSED teamApi groups read — id → name/slot) and the pure
  // docked-team rollup (live membership × 'present' fleets). Both are gated on the SAME
  // compile-time constant that mounts every other team surface (TEAM_COMMAND_ENABLED): while it is
  // false none of the team reads run and both stay empty — the map renders byte-identical to today.
  teamGroups: GroupRow[]
  dockedTeamRollups: DockedTeamRollup[]
  refresh: () => Promise<void>
}

async function fetchMainShip(mainShipId?: string | null): Promise<MainShipLite | null> {
  // Owner-read RLS returns only the caller's ship(s). Plural-safe: read ALL and resolve deterministically
  // (never `.maybeSingle()`, which errors at N≥2 → ghosts the ship). Null when none, or ambiguous >1 without
  // a selection — the map then renders no main-ship marker rather than an arbitrary one.
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select('main_ship_id, name, status, hull_type_id, hp, max_hp, cargo_capacity, spatial_state, space_x, space_y')
    .order('created_at', { ascending: true }) // stable enumeration only; the pick is resolver-decided, not first-row
  if (error) return null // non-fatal: ship is optional in Phase 9A
  return resolveOwnedShip((data ?? []) as MainShipLite[], mainShipId)
}

const EMPTY: Omit<GalaxyMapData, 'refresh'> = {
  loading: true,
  error: null,
  locations: [],
  meta: {},
  mainShip: null,
  movements: [],
  locationStates: {},
  mainshipSendEnabled: false,
  mainShipFleet: null,
  mainShipHeldFleet: null,
  mainShipPresence: null,
  mainShipSpaceMovement: null,
  teamGroups: [],
  dockedTeamRollups: [],
}

export function useGalaxyMapData(pollMs = 4000): GalaxyMapData {
  const [state, setState] = useState(EMPTY)
  const staticRef = useRef<{
    locations: MapLocation[]
    meta: Record<string, LocationMeta>
    mainshipSendEnabled: boolean
  } | null>(null)

  const load = useCallback(async () => {
    try {
      if (!staticRef.current) {
        const [world, mainshipSendEnabled] = await Promise.all([
          fetchWorldMap(), fetchMainshipSendEnabled(),
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
        staticRef.current = { locations, meta, mainshipSendEnabled }
      }

      const [movements, locationStates, mainShip] = await Promise.all([
        fetchActiveMovements(),
        fetchLocationStates(),
        fetchMainShip(),
      ])
      // The active linked fleet (zero units) drives the live main-ship status. Only read it
      // when a ship exists; absent ship or no in-flight fleet → null (home).
      const mainShipFleet = mainShip ? await fetchActiveMainShipFleet(mainShip.main_ship_id) : null
      // Slice D1: only a HELD ship (spatial_state='in_space') has a held fleet to re-send — fetch its
      // current 'completed' fleet then (and only then), mirroring the present→presence conditional below.
      const mainShipHeldFleet =
        mainShip && mainShip.spatial_state === 'in_space'
          ? await fetchHeldMainShipFleet(mainShip.main_ship_id)
          : null
      // OSN-2b: only a PRESENT fleet can validate a named-location marker — fetch its active
      // presence then (and only then). Any other state needs no presence read.
      const mainShipPresence =
        mainShipFleet && mainShipFleet.status === 'present'
          ? await fetchActiveMainShipPresence(mainShipFleet.id)
          : null
      // OSN-3 S1: at most one active coordinate movement, scoped by main_ship_id (read-only).
      const mainShipSpaceMovement = mainShip
        ? await fetchActiveMainShipSpaceMovement(mainShip.main_ship_id)
        : null
      // TEAMMAP-0: the team read set — the REUSED owner groups read, the live membership map, and
      // the docked/present fleets — folded by the PURE rollup. Compile-time gated (the teamApi
      // mount-gate law: these reads must not run against a DB predating the team migrations).
      // Poll-cost posture: the groups read goes FIRST; a team-less player (zero groups → zero
      // possible badges/rollups) skips the membership + present-fleet reads entirely, paying one
      // extra read per poll instead of three.
      const teamGroups = TEAM_COMMAND_ENABLED ? await fetchMyShipGroups() : []
      const [groupMap, presentFleets] =
        teamGroups.length > 0
          ? await Promise.all([fetchMyShipGroupMap(), fetchMyPresentShipFleets()])
          : [{}, []]
      const dockedTeamRollups = deriveDockedTeamRollups(teamGroups, groupMap, presentFleets)

      setState({
        loading: false,
        error: null,
        locations: staticRef.current.locations,
        meta: staticRef.current.meta,
        mainShip,
        movements,
        locationStates,
        mainshipSendEnabled: staticRef.current.mainshipSendEnabled,
        mainShipFleet,
        mainShipHeldFleet,
        mainShipPresence,
        mainShipSpaceMovement,
        teamGroups,
        dockedTeamRollups,
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

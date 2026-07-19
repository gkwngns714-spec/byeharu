// Types for the read-only world map (Map system). These mirror the shape returned
// by the get_world_map() RPC. Display-only — the server is authority.

export type LocationType =
  | 'pirate_hunt'
  | 'pirate_den'
  | 'mining_site'
  | 'derelict_station'
  | 'trade_outpost'
  | 'rally_point'
  | 'safe_zone'
  | 'event_site'

export type ActivityType =
  | 'hunt_pirates'
  | 'mine_resource'
  | 'explore_derelict'
  | 'trade_visit'
  | 'rally'
  | 'none'

/**
 * DISPLAY-ONLY dockability classifier — the single client source of truth for "is this location a
 * dockable port?". The seed cleanly separates them: dockable ports are `location_type='trade_outpost'`
 * (physical_role city/port + an active docking service, 0066), waypoints are `safe_zone`/`pirate_hunt`.
 * This is a HEURISTIC for choosing what to render; the server predicate
 * `mainship_space_location_target_legal` (0067: physical_role + active docking service) is the real
 * authority and still rejects a wrong guess (UI fails closed). RETIREMENT/AUTHORITY NOTE: if the seed's
 * location_type ↔ dockability coupling ever changes (e.g. a non-dockable trade_outpost, or dockability
 * exposed directly through get_world_map), update or retire THIS function — never scatter the literal.
 */
export function isDockablePortForDisplay(locationType: LocationType): boolean {
  return locationType === 'trade_outpost'
}

export interface MapLocation {
  id: string
  name: string
  location_type: LocationType
  x: number
  y: number
  base_difficulty: number
  reward_tier: number
  activity_type: ActivityType
  min_power_required: number
  is_public: boolean
  status: string
  /** S2 TERRITORY: world-unit radius of the location's zone of influence (0217). NULL = projects
   *  no territory. Additive, always present in the RPC JSON (never conditional). */
  territory_radius: number | null
}

export interface MapZone {
  id: string
  name: string
  x: number
  y: number
  radius: number
  base_difficulty: number
  max_danger_level: number
  reward_tier: number
  visibility: string
  status: string
  locations: MapLocation[]
}

export interface MapSector {
  id: string
  name: string
  sector_index: number
  x: number
  y: number
  danger_tier: number
  status: string
  zones: MapZone[]
}

export interface WorldMap {
  sectors: MapSector[]
}

/** Flatten the nested get_world_map() tree (sector → zone → locations) to the flat MapLocation list
 *  every map surface actually consumes. PURE — the single authority for this flatten so consumers
 *  (the World Editor location layer, etc.) never re-walk the tree by hand. Tolerant of missing arms. */
export function flattenWorldMapLocations(world: WorldMap): MapLocation[] {
  const out: MapLocation[] = []
  for (const sector of world.sectors ?? [])
    for (const zone of sector.zones ?? []) for (const loc of zone.locations ?? []) out.push(loc)
  return out
}

/**
 * M5: World State (dynamic). Read-only mirror of the location_state table. The
 * client never writes these — worldstate_tick() (server cron) owns them.
 */
export interface LocationState {
  location_id: string
  pressure: number
  danger_modifier: number
  active_fleets: number
}

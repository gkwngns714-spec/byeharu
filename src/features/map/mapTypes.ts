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

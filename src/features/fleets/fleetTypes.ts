// Fleet / Movement / Presence — client-side row types (read-only mirror).

export type FleetStatus = 'idle' | 'moving' | 'present' | 'returning' | 'completed' | 'destroyed'

export interface Fleet {
  id: string
  player_id: string
  origin_base_id: string | null
  status: FleetStatus
  location_mode: string
  current_location_id: string | null
  active_movement_id: string | null
  created_at: string
  updated_at: string
}

export interface FleetUnit {
  id: string
  fleet_id: string
  unit_type_id: string
  quantity: number
}

export interface FleetMovement {
  id: string
  fleet_id: string
  origin_type: string
  target_type: string
  target_location_id: string | null
  target_base_id: string | null
  mission_type: string
  status: string
  depart_at: string
  arrive_at: string
  travel_seconds: number
  travel_distance: number
}

export interface LocationPresence {
  id: string
  fleet_id: string
  location_id: string | null
  activity_type: string
  status: string
  entered_at: string
}

export interface DispatchResult {
  fleet_id: string
  movement_id: string
  arrive_at: string
}

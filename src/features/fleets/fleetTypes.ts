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
  // Set when this fleet is a main-ship expedition (Phase 10C). Such fleets carry NO fleet_units
  // and must NEVER be acted on by the legacy leave/return path — they recall via
  // request_main_ship_return only. The legacy Fleets UI excludes them on this field.
  main_ship_id: string | null
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
  origin_location_id?: string | null
  origin_base_id?: string | null
  origin_x: number
  origin_y: number
  target_type: string
  target_location_id: string | null
  target_base_id: string | null
  target_x: number
  target_y: number
  mission_type: string
  status: string
  depart_at: string
  arrive_at: string
  travel_seconds: number
  travel_distance: number
  reward_payload_json?: Record<string, number>
  // TEAMMAP-0: the parent fleet's INFORMATIONAL team tag (fleets.group_id, 0168/0187 — display
  // only; routing never reads it), flattened onto the row by fetchActiveMovements so the map can
  // label a team's in-flight fleets. Optional + additive: consumers that don't need it ignore it.
  group_id?: string | null
}

export interface LocationPresence {
  id: string
  fleet_id: string
  location_id: string | null
  activity_type: string
  status: string
  entered_at: string
}

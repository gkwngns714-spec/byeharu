// Combat — client-side row types (read-only mirror). combat_ticks are the
// authoritative log; combat_events are cosmetic. The client never computes any
// of these values.

export type CombatStatus = 'active' | 'retreating' | 'escaped' | 'defeat' | 'completed'

export interface CombatEncounter {
  id: string
  player_id: string
  fleet_id: string
  presence_id: string
  location_id: string | null
  status: CombatStatus
  tick_number: number
  danger_level: number
  waves_cleared: number
  player_power_start: number
  player_power_current: number
  enemy_power_current: number
  player_integrity_max: number
  player_integrity_current: number
  enemy_integrity_max: number
  enemy_integrity_current: number
  wave_number: number
  next_wave_at: string | null
  total_rewards_json: Record<string, number>
  started_at: string
  retreat_started_at: string | null
  ended_at: string | null
}

export interface CombatUnit {
  id: string
  encounter_id: string
  unit_type_id: string
  ship_hp: number
  initial_count: number
  alive_count: number
  hp_max: number
  hp_current: number
}

export interface CombatTick {
  id: number
  encounter_id: string
  tick_number: number
  wave_number: number
  danger_level: number
  player_power_before: number
  enemy_power: number
  player_damage: number
  enemy_damage: number
  player_integrity_before: number
  player_integrity_after: number
  enemy_integrity_before: number
  enemy_integrity_after: number
  player_losses_json: Record<string, number>
  reward_delta_json: Record<string, number>
  result: string
  resolved_at: string
}

export type CombatEventType =
  | 'missile_salvo'
  | 'laser_burst'
  | 'shield_hit'
  | 'hull_damage'
  | 'explosion'
  | 'unit_destroyed'
  | 'wave_spawned'
  | 'retreat_started'
  | 'retreat_completed'

export interface CombatEvent {
  id: number
  encounter_id: string
  tick_number: number
  seq: number
  event_type: CombatEventType
  source: string | null
  target: string | null
  projectile_type: string | null
  projectile_count: number | null
  impact_delay_ms: number | null
  payload_json: Record<string, unknown>
  created_at: string
}

export interface CombatReport {
  id: string
  encounter_id: string
  fleet_id: string | null
  location_id: string | null
  result: string
  waves_cleared: number
  duration_seconds: number
  total_losses_json: Record<string, number>
  total_rewards_json: Record<string, number>
  survivors_json: Record<string, number>
  summary_text: string | null
  created_at: string
}

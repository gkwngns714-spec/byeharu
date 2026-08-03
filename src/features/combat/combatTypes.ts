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
  // `{"metal": N, "items": [{item_id, quantity}, …]}` — a scalar key BESIDE an array key
  // (0299:1006-1010, loot_merge_items 20260617000041:51-66). It was typed `Record<string, number>`,
  // which is why two surfaces rendered `Items ×[object Object]` and silently dropped every looted
  // item. Read it through combat/rewardPayload.resolveRewardEntries — the ONE reader — never by
  // iterating its entries inline.
  total_rewards_json: Record<string, unknown>
  started_at: string
  retreat_started_at: string | null
  ended_at: string | null
  // ENGAGEMENT ANCHOR (0293) — WHERE this fight physically is, which is no longer the same question
  // as which location owns it. combat_create_group_encounter resolves it to the intercept's ambush
  // point when one was supplied, and to the linked location's centre otherwise; the intercept then
  // restates the ambush point on the row. Optional/nullable because combatApi reads `select('*')`,
  // so a server that predates the column simply omits it — consumers must fail closed on absence
  // (see ambushEncounterNotice.ts, the ONE reader).
  engagement_x?: number | null
  engagement_y?: number | null
  // THE STANDING COURSE (0337) — where this fleet has been ORDERED to, which is a different question
  // from where it currently IS (engagement_x/y above). Non-null exactly while a reposition is in
  // flight: command_ship_group_go writes the pair and moves nothing, the combat tick then walks the
  // fleet toward it at the fleet's own speed and NULLs it on arrival. Both-or-neither is a CHECK on
  // the table, so a client that sees one may rely on the other. Optional/nullable for combatApi's
  // `select('*')`, same law as the anchor: a server that predates the columns simply omits them and
  // every consumer fails closed (see repositionCourse.ts, the ONE reader).
  reposition_x?: number | null
  reposition_y?: number | null
}

export interface CombatUnit {
  id: string
  encounter_id: string
  // Slice D1 (migration 0167) widened combat_units to EXACTLY-ONE identity: a legacy catalog unit
  // (unit_type_id) XOR a team-member main ship (main_ship_id, with frozen attack/defense snapshots).
  // Member rows are DATA-DARK today — their only writer is flag-gated (team_command_enabled=false),
  // so every row a prod client can fetch still carries a non-null unit_type_id. Consumers must be
  // null-safe anyway (RoundLog/ActiveCombatPanel fall back to a ship label).
  unit_type_id: string | null
  main_ship_id?: string | null
  attack_snapshot?: number | null
  defense_snapshot?: number | null
  ship_hp: number
  initial_count: number
  alive_count: number
  hp_max: number
  hp_current: number
  // COMBAT-S3/S4 (0234) spatial columns — NULL/'player'/[] on every pre-existing and non-spatial
  // row (a select('*') read returns them once 0234 is applied). pos_x/pos_y are in the SAME world
  // domain as locations.x/y (a spatial unit is seeded from the location centre and displaced in world
  // units), so the map projects them through the SAME `norm`=worldToViewBox as every other object,
  // and weapon range scales by WORLD_TO_VIEWBOX_SCALE exactly like a territory/mining ring. NULL pos_x
  // is the fail-closed signal: while spatial_combat_enabled is dark NO encounter carries positions, so
  // the spatial map layer renders nothing (data-gated, no client flag read needed).
  pos_x?: number | null
  pos_y?: number | null
  move_speed?: number | null
  side?: 'player' | 'enemy'
  // WHEN the server last wrote this row — set to now() by the same statement that writes pos_x/pos_y
  // on every combat tick (0299's mover: `update combat_units set pos_x=…, pos_y=…, updated_at=now()`).
  // map/combatMotion.ts reads it as the ONE source for how long a step took: the gap between two
  // consecutive updated_at values IS the server's own tick interval, measured rather than assumed, so
  // the smoothing needs no hard-coded 3000 and no second read of combat_ticks. Optional because
  // combatApi reads `select('*')` — a row without it falls back to a stated default duration.
  updated_at?: string | null
  // The 0315 LEAD, as the server elected it: `is_command_ship desc, max_hp desc, main_ship_id asc`,
  // resolved ONCE per encounter, written here as 100 for the lead and 0 for every escort (NULL on
  // enemy rows, which hold no formation). The client COMPOSES this decision — it never re-derives
  // "the command ship" — see combatMotion.resolveEncounterLead.
  aggro_priority?: number | null
  // Frozen-at-spawn weapon array (0234 §S3, powers rewritten by 0331). The map reads `range` (the max
  // across weapons is the unit's range ring) and, since slice-combat-that-flows, `power` +
  // `projectile_speed` + `module_type_id` to draw the ordnance a shot actually is.
  weapons_json?: CombatWeapon[]
}

/** One entry of combat_units.weapons_json — the frozen-at-spawn description of ONE fitted gun.
 *
 *  This array is the ONE authority for what a ship shoots: 0331 (`one_authority_for_attack`) made
 *  `power` the fold's own combat_power split across the ship's guns in proportion to their catalog
 *  `module_types.power`, which is from that migration a unitless SHARE WEIGHT and never a damage
 *  number. The map therefore reads a weapon's share of its ship's volley straight off this column
 *  and never consults a client-side weapon table. */
export interface CombatWeapon {
  /** the catalog `module_types.id` this entry was frozen from — the shot's IDENTITY, restated by the
   *  server on every fire event as `combat_events.projectile_type`. */
  module_type_id?: string | null
  /** reach, world units. */
  range?: number | null
  /** world units per second — with the shot's distance this is the server's own flight time. */
  projectile_speed?: number | null
  /** post-0331: this gun's slice of its ship's combat_power per volley. */
  power?: number | null
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
  /** the SAME shape as total_rewards_json (0299:969) — read it through rewardPayload, not inline. */
  reward_delta_json: Record<string, unknown>
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
  /** the encounter's payload copied onto the report — same shape, same ONE reader. */
  total_rewards_json: Record<string, unknown>
  survivors_json: Record<string, number>
  summary_text: string | null
  created_at: string
}

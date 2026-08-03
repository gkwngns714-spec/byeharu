// THE FIGHT THE PROOFS ARE RUN AGAINST — shaped from production, not invented.
//
// Every number below is the shape the server actually writes at the current migration head:
//   · positions/ranges are POST-0316 ("combat five times tighter"): weapon ranges 5-6 world units,
//     the formation ring 6, enemies closing from the engagement anchor. That is what makes the
//     whole engagement a handful of pixels at the map's own camera — the defect the focus control
//     exists for, reproduced at true scale rather than described.
//   · `hull_damage` carries {unit_id, damage} PER LANDED HIT (0314:206-213) and is unrounded; the
//     two hits on one hull below are the real production values from tick 17 (4.136 and 4.286),
//     which the old resolver collapsed to the single number "4".
//   · `unit_destroyed` carries {unit_id, count} (0299:930-934) and lands in the SAME tick that sets
//     the target's alive_count to 0 — which is why the killing blow used to render nothing.
//   · `total_rewards_json` is `{metal, items:[{item_id, quantity}]}` (0299:1006-1010), the payload
//     that rendered as `Items ×[object Object]`.
// No production access; nothing here connects to anything.
import type { CombatEncounter, CombatEvent, CombatTick, CombatUnit } from '../../src/features/combat/combatTypes'
import type { MapLocation } from '../../src/features/map/mapTypes'

export const ENCOUNTER_ID = 'enc-1111'
export const OTHER_ENCOUNTER_ID = 'enc-2222'
export const PRESENCE_ID = 'pres-1111'

/** The fight sits just off a hostile site, where an ambush actually parks it. */
export const FIGHT_X = 1200
export const FIGHT_Y = -800

export const LOCATIONS: MapLocation[] = [
  {
    id: '11111111-1111-4111-8111-111111111111',
    name: 'Haven Reach',
    location_type: 'trade_outpost',
    x: -3000,
    y: 2000,
    base_difficulty: 1,
    reward_tier: 1,
    activity_type: 'trade_visit',
    min_power_required: 0,
    is_public: true,
    status: 'active',
    territory_radius: null,
  },
  {
    id: '22222222-2222-4222-8222-222222222222',
    name: "Reaver's Hold",
    location_type: 'pirate_hunt',
    x: FIGHT_X,
    y: FIGHT_Y,
    base_difficulty: 12,
    reward_tier: 3,
    activity_type: 'hunt_pirates',
    min_power_required: 0,
    is_public: true,
    status: 'active',
    territory_radius: null,
  },
]

const unit = (o: Partial<CombatUnit> & { id: string }): CombatUnit => ({
  encounter_id: ENCOUNTER_ID,
  unit_type_id: null,
  main_ship_id: `ship-${o.id}`,
  ship_hp: 120,
  initial_count: 1,
  alive_count: 1,
  hp_max: 120,
  hp_current: 120,
  pos_x: FIGHT_X,
  pos_y: FIGHT_Y,
  move_speed: 4,
  side: 'player',
  weapons_json: [{ range: 5.5 }],
  ...o,
})

/** Four hulls in a 6-unit formation ring against three pirates closing on the anchor — the
 *  production geometry. `p2` is the hull that takes two hits this tick; `e3` is the pirate the
 *  killing blow lands on. */
export const UNITS: CombatUnit[] = [
  unit({ id: 'p1', pos_x: FIGHT_X - 6, pos_y: FIGHT_Y, hp_current: 120 }),
  unit({ id: 'p2', pos_x: FIGHT_X, pos_y: FIGHT_Y - 6, hp_current: 41 }),
  unit({ id: 'p3', pos_x: FIGHT_X + 6, pos_y: FIGHT_Y, hp_current: 96 }),
  unit({ id: 'p4', pos_x: FIGHT_X, pos_y: FIGHT_Y + 6, hp_current: 22 }),
  unit({ id: 'e1', side: 'enemy', pos_x: FIGHT_X + 2, pos_y: FIGHT_Y - 3, hp_max: 60, hp_current: 44, weapons_json: [{ range: 5 }] }),
  unit({ id: 'e2', side: 'enemy', pos_x: FIGHT_X + 3, pos_y: FIGHT_Y - 1, hp_max: 60, hp_current: 12, weapons_json: [{ range: 5 }] }),
  // THE KILL: alive_count 0 and hp_current 0 — this is exactly the row state at the tick that
  // destroys a stack, and it is why the old splat resolver dropped both its number and its ✕.
  unit({ id: 'e3', side: 'enemy', pos_x: FIGHT_X + 1, pos_y: FIGHT_Y + 2, hp_max: 60, hp_current: 0, alive_count: 0, weapons_json: [{ range: 5 }] }),
]

const ev = (o: Partial<CombatEvent> & { id: number; event_type: CombatEvent['event_type'] }): CombatEvent => ({
  encounter_id: ENCOUNTER_ID,
  tick_number: 17,
  seq: 0,
  source: 'pirate',
  target: 'player',
  projectile_type: null,
  projectile_count: null,
  impact_delay_ms: null,
  payload_json: {},
  created_at: '2026-08-03T12:00:00Z',
  ...o,
})

export const EVENTS: CombatEvent[] = [
  // wave 1 announced TWICE by the server (t0 and t1) — the duplicate the feed must not repeat
  ev({ id: 1, event_type: 'wave_spawned', tick_number: 0, seq: 0, payload_json: { wave: 1, danger: 12, hp: 180 } }),
  ev({ id: 2, event_type: 'wave_spawned', tick_number: 1, seq: 0, payload_json: { wave: 1, danger: 12, hp: 180 } }),
  // this tick's salvos
  ev({ id: 10, event_type: 'missile_salvo', tick_number: 17, seq: 0, source: 'pirate', payload_json: { unit_id: 'e1', target_id: 'p2' } }),
  ev({ id: 11, event_type: 'missile_salvo', tick_number: 17, seq: 1, source: 'pirate', payload_json: { unit_id: 'e2', target_id: 'p2' } }),
  ev({ id: 12, event_type: 'missile_salvo', tick_number: 17, seq: 2, source: 'player', payload_json: { unit_id: 'p1', target_id: 'e3' } }),
  // TWO HITS ON ONE HULL, one tick — the production pair the map printed as a single "4"
  ev({ id: 20, event_type: 'hull_damage', tick_number: 17, seq: 3, source: 'pirate', payload_json: { unit_id: 'p2', damage: 4.136 } }),
  ev({ id: 21, event_type: 'hull_damage', tick_number: 17, seq: 4, source: 'pirate', payload_json: { unit_id: 'p2', damage: 4.286 } }),
  // THE KILLING BLOW: damage AND destruction, on a unit that is dead by the time the client reads it
  ev({ id: 22, event_type: 'hull_damage', tick_number: 17, seq: 5, source: 'player', target: 'pirate', payload_json: { unit_id: 'e3', damage: 9.4 } }),
  ev({ id: 23, event_type: 'unit_destroyed', tick_number: 17, seq: 6, source: 'player', target: 'pirate', payload_json: { unit_id: 'e3', count: 1 } }),
]

export const TICKS: CombatTick[] = [
  {
    id: 517,
    encounter_id: ENCOUNTER_ID,
    tick_number: 17,
    wave_number: 1,
    danger_level: 12,
    player_power_before: 15,
    enemy_power: 312,
    player_damage: 15,
    enemy_damage: 7.5,
    player_integrity_before: 291,
    player_integrity_after: 279,
    enemy_integrity_before: 131,
    enemy_integrity_after: 116,
    player_losses_json: {},
    reward_delta_json: {},
    result: 'ongoing',
    resolved_at: '2026-08-03T12:00:00Z',
  },
]

export const ENCOUNTER: CombatEncounter = {
  id: ENCOUNTER_ID,
  player_id: 'player-1',
  fleet_id: 'fleet-1',
  presence_id: PRESENCE_ID,
  location_id: LOCATIONS[1].id,
  status: 'active',
  tick_number: 17,
  danger_level: 12,
  waves_cleared: 0,
  player_power_start: 15,
  player_power_current: 15,
  // THE LIE: this column is the enemy's remaining INTEGRITY, not power (0299:150-156). It equals
  // enemy_integrity_current on every production row, and the card printed it against the player's
  // real power as if the two were comparable.
  enemy_power_current: 116,
  player_integrity_max: 480,
  player_integrity_current: 279,
  enemy_integrity_max: 180,
  enemy_integrity_current: 116,
  wave_number: 1,
  next_wave_at: null,
  total_rewards_json: { metal: 40, items: [{ item_id: 'scrap_alloy', quantity: 3 }] },
  started_at: '2026-08-03T11:59:00Z',
  retreat_started_at: null,
  ended_at: null,
  engagement_x: FIGHT_X,
  engagement_y: FIGHT_Y,
}

/** A SECOND, older fight far away and on a much higher tick — the case that used to blank the new
 *  battle entirely, because "the latest tick" was taken across every encounter at once. */
export const OTHER_UNITS: CombatUnit[] = [
  unit({ id: 'o1', encounter_id: OTHER_ENCOUNTER_ID, pos_x: -4000, pos_y: 3000 }),
  unit({ id: 'o2', encounter_id: OTHER_ENCOUNTER_ID, side: 'enemy', pos_x: -4004, pos_y: 3002 }),
]

export const OTHER_EVENTS: CombatEvent[] = [
  ev({ id: 90, encounter_id: OTHER_ENCOUNTER_ID, event_type: 'missile_salvo', tick_number: 80, seq: 0, payload_json: { unit_id: 'o2', target_id: 'o1' } }),
  ev({ id: 91, encounter_id: OTHER_ENCOUNTER_ID, event_type: 'hull_damage', tick_number: 80, seq: 1, payload_json: { unit_id: 'o1', damage: 3 } }),
]

export const OTHER_ENCOUNTER: CombatEncounter = {
  ...ENCOUNTER,
  id: OTHER_ENCOUNTER_ID,
  presence_id: 'pres-2222',
  fleet_id: 'fleet-2',
  tick_number: 80,
}

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
//   · `weapons_json` entries carry the WHOLE frozen object the server writes — {module_type_id,
//     range, projectile_speed, power, …} (0234:367, powers rewritten by 0331) — not just `range`.
//     The values are the live catalog's, read off production: autocannon_battery 5/60/10, the 0262
//     player fallback `basic_player_weapon` 5/60/15, `pirate_synthetic_weapon` 4/50/5.
//   · `aggro_priority` is 100 on exactly ONE player hull and 0 on the rest — 0315's elected lead, as
//     production carries it — and NULL on every enemy row, which elects none.
//   · a spatial `missile_salvo` carries `projectile_type` = the firing weapon's own module_type_id
//     and `impact_delay_ms` = the server's 1000*distance/projectile_speed (0299:878-881; verified
//     against the live process_combat_ticks source and against real event rows, which run 0-120 ms).
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
  // 0262's synthetic stand-in for a ship with nothing fitted — which is what the owner's own fleet
  // carries in production today (four rows, all `basic_player_weapon`).
  weapons_json: [{ module_type_id: 'basic_player_weapon', range: 5.5, projectile_speed: 60, power: 15 }],
  aggro_priority: 0,
  updated_at: '2026-08-03T12:00:00Z',
  ...o,
})

/** The pirate gun, verbatim from production's `pirate_synthetic_weapon`. */
const PIRATE_GUN = { module_type_id: 'pirate_synthetic_weapon', range: 5, projectile_speed: 50, power: 5 }

/** Four hulls in a 6-unit formation ring against three pirates closing on the anchor — the
 *  production geometry. `p2` is the hull that takes two hits this tick; `e3` is the pirate the
 *  killing blow lands on. */
export const UNITS: CombatUnit[] = [
  // p1 is 0315's elected LEAD (aggro_priority 100) and the only hull carrying a real fitted gun, so
  // the ordnance fallback has something to fall back TO and something to differ from.
  unit({
    id: 'p1',
    pos_x: FIGHT_X - 6,
    pos_y: FIGHT_Y,
    hp_current: 120,
    aggro_priority: 100,
    weapons_json: [{ module_type_id: 'autocannon_battery', range: 5.5, projectile_speed: 60, power: 10 }],
  }),
  unit({ id: 'p2', pos_x: FIGHT_X, pos_y: FIGHT_Y - 6, hp_current: 41 }),
  unit({ id: 'p3', pos_x: FIGHT_X + 6, pos_y: FIGHT_Y, hp_current: 96 }),
  unit({ id: 'p4', pos_x: FIGHT_X, pos_y: FIGHT_Y + 6, hp_current: 22 }),
  unit({ id: 'e1', side: 'enemy', pos_x: FIGHT_X + 2, pos_y: FIGHT_Y - 3, hp_max: 60, hp_current: 44, aggro_priority: null, weapons_json: [PIRATE_GUN] }),
  unit({ id: 'e2', side: 'enemy', pos_x: FIGHT_X + 3, pos_y: FIGHT_Y - 1, hp_max: 60, hp_current: 12, aggro_priority: null, weapons_json: [PIRATE_GUN] }),
  // THE KILL: alive_count 0 and hp_current 0 — this is exactly the row state at the tick that
  // destroys a stack, and it is why the old splat resolver dropped both its number and its ✕.
  unit({ id: 'e3', side: 'enemy', pos_x: FIGHT_X + 1, pos_y: FIGHT_Y + 2, hp_max: 60, hp_current: 0, alive_count: 0, aggro_priority: null, weapons_json: [PIRATE_GUN] }),
]

/** THE NEXT SERVER TICK, 3.0 s later — production's measured cadence (3014-3042 ms).
 *
 *  The same rows, with the two living pirates having CLOSED on the formation and their `updated_at`
 *  advanced by exactly one tick, which is how the client learns how long the step took. It exists so
 *  the rendered proof can watch a step being CROSSED: a static fixture can only ever show a unit
 *  standing still, and "the position jumps once every three seconds" is precisely the defect. */
export const UNITS_NEXT_TICK: CombatUnit[] = UNITS.map((u) => {
  const moved =
    u.id === 'e1'
      ? { pos_x: FIGHT_X + 2, pos_y: FIGHT_Y - 6.5 }
      : u.id === 'e2'
        ? { pos_x: FIGHT_X - 3.5, pos_y: FIGHT_Y - 1 }
        : {}
  return { ...u, ...moved, updated_at: '2026-08-03T12:00:03.000Z' }
})

/** THE FIGHT AFTER A REPOSITION — the same battle, somewhere else.
 *
 *  0337 turned an in-combat reposition into a real multi-tick MOVE: `combat_translate_player_formation`
 *  shifts every player hull, `fleet_set_in_space` shifts the fleet row, and `engagement_x/engagement_y`
 *  are RESTAMPED to the new point, all by ONE delta (0337:486-492) — and later waves then form around
 *  the moved anchor. This applies that same single delta to every unit and to the anchor, which is why
 *  the enemies come with it: they are part of the engagement that moved, not a separate event.
 *
 *  120 × −90 world units is ~150 units of travel — at `move_speed` 4 a reposition of about 38 ticks,
 *  and roughly 4.5 times the ~33-world-unit window the opening fit leaves. The battle is not near the
 *  edge of the old frame; it is nowhere in it. That is the state the owner was looking at. */
export const REPOSITION_DX = 120
export const REPOSITION_DY = -90

export const UNITS_REPOSITIONED: CombatUnit[] = UNITS.map((u) => ({
  ...u,
  // Every UNITS row is positioned (the `unit` builder defaults both), so `?? FIGHT_*` is unreachable
  // and never fabricates a coordinate — it only keeps the shift total on the row's own point.
  pos_x: (u.pos_x ?? FIGHT_X) + REPOSITION_DX,
  pos_y: (u.pos_y ?? FIGHT_Y) + REPOSITION_DY,
  // One tick later, so the client measures the server's own 3 s cadence for the step (combatMotion).
  updated_at: '2026-08-03T12:00:03.000Z',
}))

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
  ev({ id: 10, event_type: 'missile_salvo', tick_number: 17, seq: 0, source: 'pirate', projectile_type: 'pirate_synthetic_weapon', projectile_count: 1, impact_delay_ms: 120, payload_json: { unit_id: 'e1', target_id: 'p2' } }),
  ev({ id: 11, event_type: 'missile_salvo', tick_number: 17, seq: 1, source: 'pirate', projectile_type: 'pirate_synthetic_weapon', projectile_count: 1, impact_delay_ms: 100, payload_json: { unit_id: 'e2', target_id: 'p2' } }),
  ev({ id: 12, event_type: 'missile_salvo', tick_number: 17, seq: 2, source: 'player', projectile_type: 'autocannon_battery', projectile_count: 1, impact_delay_ms: 118, payload_json: { unit_id: 'p1', target_id: 'e3' } }),
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

/** The same encounter with its anchor RESTAMPED to where the fight now is — 0337 writes
 *  `engagement_x/engagement_y` in the same statement that moves the formation, so a fixture that
 *  moved the hulls and left the anchor behind would be a state the server cannot produce. */
export const ENCOUNTER_REPOSITIONED: CombatEncounter = {
  ...ENCOUNTER,
  engagement_x: FIGHT_X + REPOSITION_DX,
  engagement_y: FIGHT_Y + REPOSITION_DY,
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

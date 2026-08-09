import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  FLEET_STAT_LABEL,
  fireRateText,
  resolveFightingFleetStats,
  trim,
  weaponSystemsText,
} from '../src/features/map/fightingFleetStats'
import type { CombatUnit } from '../src/features/combat/combatTypes'

// ██ WHAT MY FLEET CAN DO IN THIS FIGHT — pure unit proof of reach, rate of fire and combat speed. ██
//
// Owner: "the fleets info tab should have info like range, speed, reload time, etc".
//
// ── THE TWO RULES THAT SHAPE THIS LEAF ────────────────────────────────────────────────────────────
// 1. NONE OF THESE IS A REGISTRY STAT, AND NONE MAY BECOME ONE. STAT_ARCHITECTURE_CONTRACT §11.3
//    (:995-997) lists "model weapon range, projectile speed, cooldown or ammo as registry stats"
//    among the things the architecture will NOT do; 0340:512-515 names the shipped defect that
//    earned the rule. They are per-weapon geometry frozen onto combat_units, read here through the
//    EXISTING range authority — no fourth label vocabulary is created.
// 2. THE FLEET IS THE ACTOR. One number each for the whole fleet, never a per-hull table.
//
// ── ██ AND THE MEASURED REASON `cooldown_seconds` IS NOT SHOWN ██ ────────────────────────────────
// The tick's fire gate is `(v_w_next_ready is null or now() >= v_w_next_ready)` and after firing it
// stamps `next_ready_at := now()` — NOT `now() + cooldown_seconds` (0299:870-873 and :947, the same
// two lines in every re-create back to 0234). So the gate is satisfied on every subsequent tick
// whatever the cooldown says: the column is carried and read by nothing. Printing it would put a
// number on screen that changes nothing in the game. What the player experiences is the ROUND, and
// that is what the line states.
//
// No browser, no page, no DB. Run: `npx playwright test fightingFleetStats.spec.ts`.

const ENC = 'enc-1'
let n = 0
const hull = (over: Partial<CombatUnit>): CombatUnit =>
  ({
    id: `u-${n++}`,
    encounter_id: ENC,
    unit_type_id: null,
    main_ship_id: 'ship-a',
    ship_hp: 120,
    initial_count: 1,
    alive_count: 1,
    hp_max: 120,
    hp_current: 100,
    pos_x: 500,
    pos_y: 500,
    side: 'player',
    ...over,
  }) as CombatUnit

// ── REACH ────────────────────────────────────────────────────────────────────────────────────────

test('reach is the FURTHEST gun across the living hulls — the fleet is one actor', () => {
  const units = [
    hull({ weapons_json: [{ range: 5 }, { range: 6 }] }),
    hull({ weapons_json: [{ range: 4 }] }),
  ]
  expect(resolveFightingFleetStats(units, ENC, 3)!.reach).toBe(6)
})

test('a DESTROYED hull contributes no reach — a dead gun does not extend the fleet', () => {
  const units = [
    hull({ alive_count: 0, weapons_json: [{ range: 99 }] }),
    hull({ weapons_json: [{ range: 6 }] }),
  ]
  expect(resolveFightingFleetStats(units, ENC, 3)!.reach).toBe(6)
})

test('an unarmed fleet reaches NOTHING, and says so rather than printing 0', () => {
  const units = [hull({ weapons_json: [] }), hull({ weapons_json: [{ range: null }] })]
  expect(resolveFightingFleetStats(units, ENC, 3)!.reach).toBeNull()
})

test('enemy hulls are not my fleet, and another fight is not this one', () => {
  const units = [
    hull({ side: 'enemy', weapons_json: [{ range: 99 }] }),
    hull({ encounter_id: 'enc-other', weapons_json: [{ range: 88 }] }),
    hull({ weapons_json: [{ range: 6 }] }),
  ]
  const v = resolveFightingFleetStats(units, ENC, 3)!
  expect(v.reach).toBe(6)
  expect(v.hullsAlive).toBe(1)
})

// ── COMBAT SPEED ─────────────────────────────────────────────────────────────────────────────────

test('combat speed is the SLOWEST living hull — the rule 0337’s tick walks the fleet by', () => {
  const units = [hull({ move_speed: 1 }), hull({ move_speed: 0.6 }), hull({ move_speed: 0.8 })]
  expect(resolveFightingFleetStats(units, ENC, 3)!.speed).toBe(0.6)
})

test('a dead hull cannot slow the fleet down', () => {
  const units = [hull({ alive_count: 0, move_speed: 0.1 }), hull({ move_speed: 0.6 })]
  expect(resolveFightingFleetStats(units, ENC, 3)!.speed).toBe(0.6)
})

test('a row with no reported speed yields NULL, never a fabricated one', () => {
  for (const bad of [null, undefined, 0, Number.NaN]) {
    const units = [hull({ move_speed: bad as number | null })]
    expect(resolveFightingFleetStats(units, ENC, 3)!.speed).toBeNull()
  }
})

// ── RATE OF FIRE ─────────────────────────────────────────────────────────────────────────────────

test('the cadence is the ROUND, with the round’s own length beside it', () => {
  expect(fireRateText(3)).toBe('every round · 3s')
  expect(fireRateText(6)).toBe('every round · 6s')
})

test('an unreadable knob drops the NUMBER, not the fact — never a plausible default', () => {
  // The retreatCountdown law: a `?? 20` fallback two and a half times production's real window is
  // how a surface lies confidently. Absent → state the cadence and no duration.
  for (const bad of [null, 0, -1, Number.NaN]) {
    expect(fireRateText(bad)).toBe('every round')
  }
  expect(resolveFightingFleetStats([hull({})], ENC, null)!.roundSeconds).toBeNull()
  expect(resolveFightingFleetStats([hull({})], ENC, Number.NaN)!.roundSeconds).toBeNull()
})

// ── NOTHING TO SAY ───────────────────────────────────────────────────────────────────────────────

test('no living player hull in this fight → NULL, and the readout shows no fight stats at all', () => {
  expect(resolveFightingFleetStats([], ENC, 3)).toBeNull()
  expect(resolveFightingFleetStats([hull({ alive_count: 0 })], ENC, 3)).toBeNull()
  expect(resolveFightingFleetStats([hull({ side: 'enemy' })], ENC, 3)).toBeNull()
})

test('hullsAlive sums alive_count — a unit row is a STACK, not one ship', () => {
  expect(resolveFightingFleetStats([hull({ alive_count: 2 }), hull({ alive_count: 1 })], ENC, 3)!.hullsAlive).toBe(3)
})

test('display trimming never invents precision', () => {
  expect(trim(6)).toBe('6')
  expect(trim(0.6)).toBe('0.6')
  expect(trim(0.6666)).toBe('0.67')
})

// ── ONE AUTHORITY, AND NO COOLDOWN ───────────────────────────────────────────────────────────────

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', rel), 'utf8')

test('the range derivation is COMPOSED, never re-implemented', () => {
  const source = src('features/map/fightingFleetStats.ts')
  expect(source).toContain("import { unitWeaponRange } from './spatialCombatLayer'")
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  expect(code, 'the strip did not eat the code').toContain('export function resolveFightingFleetStats')
  expect(code, 'no second walk of weapons_json for range').not.toContain("w?.range")
  // ██ the measured refusal ██ — the engine never reads cooldown_seconds, so no surface may show it.
  expect(code, 'cooldown_seconds changes nothing in the engine and must not reach a screen').not.toContain(
    'cooldown_seconds',
  )
  for (const forbidden of ['react', 'Date.now(', 'supabase', 'Math.random']) {
    expect(code, `fightingFleetStats.ts must not contain ${forbidden}`).not.toContain(forbidden)
  }
})

test('the client type still declares no cooldown — the data is on the wire and deliberately unread', () => {
  const types = src('features/combat/combatTypes.ts')
  const weapon = types.slice(types.indexOf('export interface CombatWeapon'))
  expect(weapon.slice(0, weapon.indexOf('}')), 'CombatWeapon must not grow a dead field').not.toContain(
    'cooldown_seconds',
  )
})

test('the fleet readout composes the leaf rather than folding its own numbers', () => {
  const model = src('features/map/fleetStatusModel.ts')
  expect(model).toContain("from './fightingFleetStats'")
  expect(model).toContain('resolveFightingFleetStats(')
  const code = model.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  expect(code, 'no local max over weapon ranges').not.toContain('weapons_json')
  expect(code, 'no local min over move speeds').not.toContain('move_speed')
  // …and no local hull/shield/attack fold either — the four the owner asked for on 2026-08-09 must
  // arrive from the leaf, or they become a second aggregation of the same rows.
  for (const col of ['hp_current', 'hp_max', 'shield_current', 'shield_max', 'module_type_id']) {
    expect(code, `the readout must not read ${col} itself`).not.toContain(col)
  }
})

// ══ ATTACK — the engine's own per-round volley (owner: "attacking power") ═════════════════════════
// 0331 (`one_authority_for_attack`) rewrote weapons_json[i].power to be the ship's folded
// combat_power split across its guns in proportion to module_types.power. So a ship's weapons sum
// EXACTLY to its combat_power, and the fleet's sum is what it puts out in one round. Nothing is
// scaled, curved or modified here — the defence curve is the server's, applied on arrival.

test('attack is every gun on every LIVING hull, summed', () => {
  const units = [
    hull({ weapons_json: [{ power: 15 }, { power: 9 }] }),
    hull({ weapons_json: [{ power: 15 }] }),
  ]
  expect(resolveFightingFleetStats(units, ENC, 3)!.attack).toBe(39)
})

test('a dead hull, an enemy hull and another fight’s hull all contribute NO attack', () => {
  const units = [
    hull({ alive_count: 0, weapons_json: [{ power: 999 }] }),
    hull({ side: 'enemy', weapons_json: [{ power: 999 }] }),
    hull({ encounter_id: 'enc-other', weapons_json: [{ power: 999 }] }),
    hull({ weapons_json: [{ power: 15 }] }),
  ]
  expect(resolveFightingFleetStats(units, ENC, 3)!.attack).toBe(15)
})

test('an unarmed fleet has NO attack — null, never a 0 that reads as "it does no damage"', () => {
  // The distinction is the whole honesty rule: 0 is a claim about the fleet; null is "the rows do
  // not say", and the readout then prints nothing at all.
  for (const w of [[], [{ power: null }], [{ power: 0 }], [{ power: Number.NaN }]]) {
    expect(resolveFightingFleetStats([hull({ weapons_json: w as never })], ENC, 3)!.attack).toBeNull()
  }
})

// ══ WEAPONS — "what weapon system it is using" ════════════════════════════════════════════════════

test('the weapon systems are the DISTINCT modules across the living hulls, counted', () => {
  const units = [
    hull({ weapons_json: [{ module_type_id: 'basic_player_weapon', power: 15 }] }),
    hull({ weapons_json: [{ module_type_id: 'basic_player_weapon', power: 15 }] }),
    hull({ weapons_json: [{ module_type_id: 'mod_shield_booster', power: 4 }] }),
  ]
  const v = resolveFightingFleetStats(units, ENC, 3)!
  // Most-fitted first, so the fleet's main armament reads first and the order is stable across polls.
  expect(v.weapons.map((w) => [w.id, w.count])).toEqual([
    ['basic_player_weapon', 2],
    ['mod_shield_booster', 1],
  ])
  // Humanised through the ONE client id→name authority, so a module is called the same thing here
  // as on the fitting screen and in a loot chip.
  expect(v.weapons[0].name).toBe('Basic Player Weapon')
})

test('a gun with no stated POWER is still a fitted SYSTEM — the two reads are independent', () => {
  // "What am I shooting with" and "how hard" are different questions. A weapon whose power the row
  // does not state must not vanish from the first one.
  const v = resolveFightingFleetStats(
    [hull({ weapons_json: [{ module_type_id: 'basic_player_weapon', power: null }] })],
    ENC,
    3,
  )!
  expect(v.attack).toBeNull()
  expect(v.weapons.map((w) => w.id)).toEqual(['basic_player_weapon'])
})

test('a weapon that names no module is counted for damage but not listed as a system', () => {
  const v = resolveFightingFleetStats([hull({ weapons_json: [{ power: 15 }] })], ENC, 3)!
  expect(v.attack).toBe(15)
  expect(v.weapons).toEqual([])
})

test('the systems line reads as words, and a single gun is not padded with "×1"', () => {
  expect(weaponSystemsText([{ id: 'a', name: 'Basic Player Weapon', count: 5 }])).toBe('Basic Player Weapon ×5')
  expect(weaponSystemsText([{ id: 'a', name: 'Rail Cannon', count: 1 }])).toBe('Rail Cannon')
  expect(
    weaponSystemsText([
      { id: 'a', name: 'Rail Cannon', count: 2 },
      { id: 'b', name: 'Pulse Laser', count: 1 },
    ]),
  ).toBe('Rail Cannon ×2, Pulse Laser')
  expect(weaponSystemsText([])).toBe('')
})

// ══ HULL ═════════════════════════════════════════════════════════════════════════════════════════

test('hull is Σ current / Σ max over the LIVING hulls — the engine’s own integrity summation', () => {
  const units = [
    hull({ hp_current: 473, hp_max: 500 }),
    hull({ hp_current: 33, hp_max: 500 }),
    hull({ alive_count: 0, hp_current: 0, hp_max: 500 }),
    hull({ side: 'enemy', hp_current: 180, hp_max: 180 }),
  ]
  expect(resolveFightingFleetStats(units, ENC, 3)!.hull).toEqual({ current: 506, max: 1000 })
})

test('a row with no usable max contributes NEITHER side — never a wrong denominator', () => {
  const units = [hull({ hp_current: 50, hp_max: 0 }), hull({ hp_current: 100, hp_max: 200 })]
  expect(resolveFightingFleetStats(units, ENC, 3)!.hull).toEqual({ current: 100, max: 200 })
  expect(resolveFightingFleetStats([hull({ hp_current: 5, hp_max: 0 })], ENC, 3)!.hull).toBeNull()
})

test('current is CLAMPED into its own bar — a row can never read as 120% or as negative hull', () => {
  const units = [hull({ hp_current: 900, hp_max: 500 }), hull({ hp_current: -40, hp_max: 500 })]
  expect(resolveFightingFleetStats(units, ENC, 3)!.hull).toEqual({ current: 500, max: 1000 })
})

// ══ ██ SHIELD AND SHIELD GENERATION — REAL MECHANICS, ZERO EVERYWHERE ON PRODUCTION ██ ════════════
// combat_units.shield_current/shield_max exist (0191) and the tick genuinely regenerates and absorbs
// with them (0195). MEASURED ON PRODUCTION 2026-08-09: 0 of 327 combat_units rows carry a pool, 0 of
// 77 ships have max_shield > 0, 0 of 3 hulls have base_shield > 0, and shield_regen_combat_pct is 0.
// The stack is DATA-gated with no flag — scripts/activate-shield.sql is the human flip.
//
// So the rule is the readout's standing one: a number that changes nothing in the game must not
// appear. These pin BOTH halves — the silence today, and the lines lighting up on their own.

test('no living hull carries a pool → NO shield and NO regen. Never 0/0, never "regen 0"', () => {
  // 0191 pairs the columns by CHECK and a shieldless hull carries NULL/NULL rather than 0/0
  // precisely so "no shield machinery" stays distinguishable from "shield down".
  const v = resolveFightingFleetStats([hull({}), hull({})], ENC, 3, 0.02)!
  expect(v.shield).toBeNull()
  expect(v.shieldRegenPerRound).toBeNull()
})

test('a pool that exists IS shown, summed over the living hulls', () => {
  const units = [
    hull({ shield_current: 60, shield_max: 100 }),
    hull({ shield_current: 100, shield_max: 100 }),
    hull({ alive_count: 0, shield_current: 100, shield_max: 100 }),
    hull({ side: 'enemy', shield_current: 500, shield_max: 500 }),
    hull({}), // a shieldless hull in the same fleet contributes nothing to either side
  ]
  expect(resolveFightingFleetStats(units, ENC, 3, null)!.shield).toEqual({ current: 160, max: 200 })
})

test('regen is Σ max × the knob the ENGINE reads — and it is silent unless BOTH are real', () => {
  const pooled = [hull({ shield_current: 60, shield_max: 100 }), hull({ shield_current: 60, shield_max: 100 })]
  // 0195: `shield := least(shield_max, shield_current + shield_max × shield_regen_combat_pct)`.
  expect(resolveFightingFleetStats(pooled, ENC, 3, 0.02)!.shieldRegenPerRound).toBeCloseTo(4)
  // A pool with no regen and a regen with no pool are two DIFFERENT silences, and neither prints.
  for (const knob of [null, undefined, 0, -1, Number.NaN]) {
    expect(
      resolveFightingFleetStats(pooled, ENC, 3, knob as number | null)!.shieldRegenPerRound,
      `knob ${String(knob)} must not produce a regen line`,
    ).toBeNull()
  }
  expect(resolveFightingFleetStats([hull({})], ENC, 3, 0.02)!.shieldRegenPerRound).toBeNull()
})

test('the knob defaults to ABSENT — a caller that has not read it can never light the mechanic', () => {
  const pooled = [hull({ shield_current: 60, shield_max: 100 })]
  expect(resolveFightingFleetStats(pooled, ENC, 3)!.shieldRegenPerRound).toBeNull()
})

// ══ THE WORDS ════════════════════════════════════════════════════════════════════════════════════

test('the labels are the OWNER’S words — no jargon, and the two speeds can never be confused', () => {
  // He reported "range" and "moving speed" as MISSING from a readout that was printing "Reach" and
  // "Combat speed" at that exact moment. A stat the player does not recognise is not there.
  expect(FLEET_STAT_LABEL.range).toBe('Range')
  expect(FLEET_STAT_LABEL.speed).toBe('Speed in battle')
  expect(FLEET_STAT_LABEL.attack).toBe('Attack')
  expect(FLEET_STAT_LABEL.weapons).toBe('Weapons')
  expect(FLEET_STAT_LABEL.hull).toBe('Hull')
  // The combat speed is world-units-per-round; the map-travel speed is a different quantity in a
  // different unit. The label must carry that distinction on its own, without a footnote.
  expect(FLEET_STAT_LABEL.speed).not.toBe('Speed')
  expect(Object.values(FLEET_STAT_LABEL)).not.toContain('Reach')
})

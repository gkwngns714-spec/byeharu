import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { fireRateText, resolveFightingFleetStats, trim } from '../src/features/map/fightingFleetStats'
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
})

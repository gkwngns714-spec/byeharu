import { test, expect } from '@playwright/test'
import { resolveFleetFightPosition } from '../src/features/map/fleetFightPosition'
import type { CombatUnit } from '../src/features/combat/combatTypes'
import type { FleetEncounterLite } from '../src/features/combat/encounterAnchor'

// WHERE IS THIS FLEET WHILE IT FIGHTS — pure specs for the ONE shared rule. No I/O, no clock.
//
// The numbers are the real production measurement of the owner's last spatial fight:
//
//     side     units   min dist from the parked anchor   max
//     enemy      3               5.00                    5.00
//     player     4              21.50                   28.68
//
// The badge stood on the anchor while the fleet's own ships stood ~25 units away — the same fleet
// rendered twice, in two places. The rule: while a live encounter carries positioned living player
// units, the fleet is at their CENTROID; otherwise it is exactly where the caller says it rests.

const PARK = { x: -27, y: 97 }
const CENTROID = { x: -2, y: 97 } // PARK + (25, 0)

const unit = (o: Partial<CombatUnit> = {}): CombatUnit => ({
  id: 'u1',
  encounter_id: 'e1',
  unit_type_id: null,
  ship_hp: 10,
  initial_count: 1,
  alive_count: 1,
  hp_max: 10,
  hp_current: 10,
  side: 'player',
  pos_x: 0,
  pos_y: 0,
  ...o,
})

// Four ships in a box 20-30 east of the park → centroid exactly PARK + (25, 0).
const formation = (): CombatUnit[] => [
  unit({ id: 'p1', pos_x: PARK.x + 20, pos_y: PARK.y + 10 }),
  unit({ id: 'p2', pos_x: PARK.x + 30, pos_y: PARK.y + 10 }),
  unit({ id: 'p3', pos_x: PARK.x + 20, pos_y: PARK.y - 10 }),
  unit({ id: 'p4', pos_x: PARK.x + 30, pos_y: PARK.y - 10 }),
]
const enemies = (): CombatUnit[] => [
  unit({ id: 'e-a', side: 'enemy', pos_x: PARK.x + 5, pos_y: PARK.y }),
  unit({ id: 'e-b', side: 'enemy', pos_x: PARK.x, pos_y: PARK.y + 5 }),
  unit({ id: 'e-c', side: 'enemy', pos_x: PARK.x - 5, pos_y: PARK.y }),
]

const enc = (o: Partial<FleetEncounterLite> = {}): FleetEncounterLite => ({
  id: 'e1',
  fleet_id: 'fleet-1',
  status: 'active',
  ...o,
})

const at = (encounters: FleetEncounterLite[], units: CombatUnit[], fallback = PARK) =>
  resolveFleetFightPosition({ fleetId: 'fleet-1', encounters, units, fallback })

// ── the formation arm ────────────────────────────────────────────────────────────────────────────
test('a live fight with positioned player ships puts the fleet on their centroid', () => {
  expect(at([enc()], formation())).toEqual({ ...CENTROID, source: 'formation', fighting: true })
})

test('the centroid is the mean of the PROD spread, not the anchor it started from', () => {
  const A = { x: -27.37, y: 97.04 }
  const p = resolveFleetFightPosition({
    fleetId: 'fleet-1',
    encounters: [enc()],
    units: [
      unit({ id: 'p1', pos_x: A.x + 21.5, pos_y: A.y }),
      unit({ id: 'p2', pos_x: A.x + 28.68, pos_y: A.y }),
    ],
    fallback: A,
  })!
  expect(p.source).toBe('formation')
  expect(p.x).toBeCloseTo(A.x + 25.09, 6)
  expect(p.y).toBeCloseTo(A.y, 6)
  expect(Math.abs(p.x - A.x)).toBeGreaterThan(21) // demonstrably not the fallback
})

test('enemies never fold into the player formation (they sat 5.00 out in prod)', () => {
  expect(at([enc()], [...formation(), ...enemies()])).toMatchObject(CENTROID)
  // enemies ALONE are not a formation — the fleet has no living ship to stand with
  expect(at([enc()], enemies())).toEqual({ ...PARK, source: 'fallback', fighting: true })
})

test('a destroyed or unpositioned ship does not vote (the same filter that gives it no glyph)', () => {
  expect(at([enc()], [...formation(), unit({ id: 'dead', alive_count: 0, pos_x: 1e6, pos_y: 1e6 })])).toMatchObject(
    CENTROID,
  )
  expect(at([enc()], [...formation(), unit({ id: 'flat', pos_x: null, pos_y: null })])).toMatchObject(CENTROID)
  expect(at([enc()], [...formation(), unit({ id: 'nan', pos_x: Number.NaN, pos_y: 5 })])).toMatchObject(CENTROID)
})

test('another encounter’s units never drag this fleet', () => {
  expect(
    at([enc()], [...formation(), unit({ id: 'x', encounter_id: 'e-other', pos_x: 1e6, pos_y: 1e6 })]),
  ).toMatchObject(CENTROID)
})

test('a single ship is its own centroid', () => {
  expect(at([enc()], [unit({ pos_x: 5, pos_y: -5 })])).toEqual({ x: 5, y: -5, source: 'formation', fighting: true })
})

// ── the fallback arm — "exactly today's behaviour" ───────────────────────────────────────────────
test('no encounter at all → the caller’s resting point, not fighting', () => {
  expect(at([], formation())).toEqual({ ...PARK, source: 'fallback', fighting: false })
})

test('an ENDED encounter is not a live fight', () => {
  for (const status of ['escaped', 'defeat', 'completed']) {
    expect(at([enc({ status })], formation())).toEqual({ ...PARK, source: 'fallback', fighting: false })
  }
})

test('another fleet’s encounter is not this fleet’s fight', () => {
  expect(at([enc({ fleet_id: 'fleet-2' })], formation())).toEqual({ ...PARK, source: 'fallback', fighting: false })
})

test('TWO live encounters for one fleet (a broken invariant) → resting, never a coin flip', () => {
  const pair = [enc(), enc({ id: 'e2' })]
  expect(at(pair, formation())).toEqual({ ...PARK, source: 'fallback', fighting: false })
})

test('fighting but UNPOSITIONED (an aggregate fight) rests in place yet still reads as fighting', () => {
  expect(at([enc()], [unit({ pos_x: null, pos_y: null })])).toEqual({ ...PARK, source: 'fallback', fighting: true })
  expect(at([enc()], [])).toEqual({ ...PARK, source: 'fallback', fighting: true })
})

test('a retreating fleet is still being shot at, so it still follows its formation', () => {
  expect(at([enc({ status: 'retreating' })], formation())).toMatchObject({ ...CENTROID, fighting: true })
})

// ── fail closed ──────────────────────────────────────────────────────────────────────────────────
test('an unusable FALLBACK is the only null — the caller then draws nothing at all', () => {
  for (const bad of [
    { x: Number.NaN, y: 97 },
    { x: -27, y: Number.NaN },
    { x: Number.POSITIVE_INFINITY, y: 0 },
  ]) {
    expect(at([enc()], formation(), bad)).toBeNull() // even with a perfectly good formation
    expect(at([], [], bad)).toBeNull()
  }
})

test('no fleet id → resting, and never an exception', () => {
  for (const id of [null, undefined, '']) {
    expect(
      resolveFleetFightPosition({ fleetId: id, encounters: [enc()], units: formation(), fallback: PARK }),
    ).toEqual({ ...PARK, source: 'fallback', fighting: false })
  }
})

test('every non-null answer is finite and never silently the origin', () => {
  for (const p of [at([enc()], formation()), at([], []), at([enc()], [])]) {
    expect(p).not.toBeNull()
    expect(Number.isFinite(p!.x) && Number.isFinite(p!.y)).toBe(true)
    expect(p!.x === 0 && p!.y === 0).toBe(false)
  }
})

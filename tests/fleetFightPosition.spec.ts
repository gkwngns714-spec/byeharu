import { test, expect } from '@playwright/test'
import { resolveFleetFightPosition } from '../src/features/map/fleetFightPosition'
import type { CombatUnit } from '../src/features/combat/combatTypes'
import type { FleetEncounterLite } from '../src/features/combat/encounterAnchor'

// WHERE IS THIS FLEET WHILE IT FIGHTS — pure specs for the ONE shared rule. No I/O, no clock.
//
// ── THE OWNER'S REAL FIGHT, MEASURED ON PRODUCTION ────────────────────────────────────────────────
// After the previous fix shipped: "the fleet arrived at combat zone, it fights but in a different
// location. This is not fixed". The measurement of that exact fight:
//
//     enemies : 3 units at EXACTLY one point, spread 0.0 x 0.0, 5.0 from the engagement anchor
//     player  : 4 units, 20.7-28.1 from the anchor, 10.1-21.2 from their own centroid
//     badge   : on that centroid — a point where NO ship is, ~16.3 from the enemy stack
//
// A centroid is only meaningful for a CLUSTER. These ships are scattered, so their mean is empty
// space between them while the shooting happens at the enemy stack. THAT is "it fights but in a
// different location", and it is why every spec below asserts MEMBERSHIP (the badge equals one of
// the input positions EXACTLY), not proximity. An average can never satisfy membership, so the
// centroid cannot come back without turning these red.
//
// The anchor below is derived from the measurement and reproduces it: it is 5.0 from the enemy
// stack and 20.70 / 24.66 / 22.81 / 28.18 from the four ships — the reported 5.0 and 20.7-28.1.
const ANCHOR = { x: -31.968, y: 96.627 } // = the fleet's parked space_x/space_y on the ambush arm
const ENEMY = { x: -27.0, y: 97.2 } // three enemy units, all on this one point
const SPARROW = { x: -11.4, y: 99.0 } // Sparrow V — 15.70 from the enemy stack: the point of attack
const CENTROID = { x: -26.15, y: 113.475 } // the previous answer: a point with no ship on it
// Distances from the enemy stack: Sparrow 15.70 · p2 21.60 · p3 26.01 · p4 27.45.
const PROD_SHIPS = [
  { id: 'p1-sparrow', ...SPARROW },
  { id: 'p2-kite', x: -17.5, y: 116.6 },
  { id: 'p3-far', x: -47.1, y: 113.7 },
  { id: 'p4-rear', x: -28.6, y: 124.6 },
] as const

// The stability band, in world units, that the resolver treats as "the same distance" before it
// will move the badge to a different hull. Mirrors NEAREST_SHIP_MARGIN in the implementation; kept
// as a literal here so the spec pins the shipped VALUE rather than restating whatever it becomes.
// 0316 divided every combat distance by 5 (weapon ranges 25-30 -> 5-6, formation ring 30 -> 6) and
// this band is a combat distance, so it divided with them: 1 -> 0.2.
const MARGIN = 0.2

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

const ship = (p: { id: string; x: number; y: number }, o: Partial<CombatUnit> = {}) =>
  unit({ id: p.id, pos_x: p.x, pos_y: p.y, ...o })

const prodPlayers = (): CombatUnit[] => PROD_SHIPS.map((s) => ship(s))
const prodEnemies = (): CombatUnit[] =>
  ['e-a', 'e-b', 'e-c'].map((id) => unit({ id, side: 'enemy', pos_x: ENEMY.x, pos_y: ENEMY.y }))

const enc = (o: Partial<FleetEncounterLite> = {}): FleetEncounterLite => ({
  id: 'e1',
  fleet_id: 'fleet-1',
  status: 'active',
  ...o,
})

const at = (encounters: FleetEncounterLite[], units: CombatUnit[], fallback = ANCHOR) =>
  resolveFleetFightPosition({ fleetId: 'fleet-1', encounters, units, fallback })

const positionsOf = (units: readonly CombatUnit[]) =>
  units.map((u) => `${u.pos_x},${u.pos_y}`)

// ── THE REGRESSION THIS FILE EXISTS FOR ──────────────────────────────────────────────────────────
test('THE OWNER’S PRODUCTION FIGHT: the badge stands on Sparrow V, the ship nearest the enemy', () => {
  const p = at([enc()], [...prodPlayers(), ...prodEnemies()])!
  expect({ x: p.x, y: p.y }).toEqual(SPARROW)
  expect(p.unitId).toBe('p1-sparrow')
  expect(p.source).toBe('unit')
  expect(p.fighting).toBe(true)
})

test('THE OWNER’S PRODUCTION FIGHT: the badge is NOT the centroid — nothing is standing there', () => {
  const p = at([enc()], [...prodPlayers(), ...prodEnemies()])!
  expect({ x: p.x, y: p.y }).not.toEqual(CENTROID)
  // and it is not merely "near" a ship — it IS one (see the membership spec below)
  expect(positionsOf(prodPlayers())).toContain(`${p.x},${p.y}`)
  // the centroid genuinely is empty space: no input ship sits on it
  expect(positionsOf(prodPlayers())).not.toContain(`${CENTROID.x},${CENTROID.y}`)
})

// ── MEMBERSHIP: the invariant that makes "an average" structurally impossible ─────────────────────
test('MEMBERSHIP: the answer is always EXACTLY one of the input unit positions, never between them', () => {
  // A deterministic sweep of scattered formations. A mean, a midpoint, a bounding-box centre or any
  // other synthesised point fails this for all but a contrived input; a real hull passes always.
  let seed = 1337
  const rand = () => {
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
  }
  for (let trial = 0; trial < 200; trial++) {
    const n = 1 + Math.floor(rand() * 6)
    const players: CombatUnit[] = []
    for (let i = 0; i < n; i++) {
      players.push(ship({ id: `s${i}`, x: (rand() - 0.5) * 400, y: (rand() - 0.5) * 400 }))
    }
    const foes: CombatUnit[] = []
    for (let i = 0; i < 1 + Math.floor(rand() * 3); i++) {
      foes.push(unit({ id: `f${i}`, side: 'enemy', pos_x: (rand() - 0.5) * 400, pos_y: (rand() - 0.5) * 400 }))
    }
    const p = at([enc()], [...players, ...foes], { x: (rand() - 0.5) * 400, y: (rand() - 0.5) * 400 })!
    expect(p.source).toBe('unit')
    const hull = players.find((u) => u.id === p.unitId)
    expect(hull).toBeTruthy()
    expect(p.x).toBe(hull!.pos_x) // identity, not closeness
    expect(p.y).toBe(hull!.pos_y)
    // and it is within the stability margin of the genuinely nearest ship
    const scoreOf = (u: CombatUnit) =>
      Math.min(...foes.map((f) => Math.hypot((u.pos_x as number) - (f.pos_x as number), (u.pos_y as number) - (f.pos_y as number))))
    const best = Math.min(...players.map(scoreOf))
    expect(scoreOf(hull!)).toBeLessThanOrEqual(best + MARGIN + 1e-9)
  }
})

test('MEMBERSHIP holds on the enemy-less arm too (nearest the anchor is still a real hull)', () => {
  const p = at([enc()], prodPlayers())!
  expect(p.source).toBe('unit')
  expect(positionsOf(prodPlayers())).toContain(`${p.x},${p.y}`)
})

// ── THE TARGET IS THE ENEMY; THE ANSWER IS ALWAYS OURS ───────────────────────────────────────────
test('the enemy is the distance TARGET and never the position — the badge is always one of OUR hulls', () => {
  const p = at([enc()], [...prodPlayers(), ...prodEnemies()])!
  expect({ x: p.x, y: p.y }).not.toEqual(ENEMY)
  expect(['e-a', 'e-b', 'e-c']).not.toContain(p.unitId)
})

test('moving the ENEMY moves which of OUR ships is chosen, and only that', () => {
  // put the enemy stack behind the rear ship instead: the rear ship becomes the point of attack
  const behind = ['e-a', 'e-b', 'e-c'].map((id) => unit({ id, side: 'enemy', pos_x: -28.6, pos_y: 140 }))
  const p = at([enc()], [...prodPlayers(), ...behind])!
  expect(p.unitId).toBe('p4-rear')
  expect({ x: p.x, y: p.y }).toEqual({ x: -28.6, y: 124.6 })
})

test('enemies ALONE are not a formation — the fleet has no living hull to stand on', () => {
  const p = at([enc()], prodEnemies())!
  expect({ x: p.x, y: p.y }).toEqual(ANCHOR)
  expect(p.source).toBe('fallback')
  expect(p.unitId).toBeNull()
  expect(p.fighting).toBe(true)
})

// ── NO ENEMIES → NEAREST THE ENGAGEMENT ANCHOR ───────────────────────────────────────────────────
test('with no living positioned enemy, the badge takes the hull nearest the ENGAGEMENT ANCHOR', () => {
  // Two ships. A is nearer the anchor; B would be nearer the (absent) enemy side. Only the anchor
  // rule can pick A, so this fixture tells the two rules apart.
  const A = ship({ id: 'a-near-anchor', x: 10, y: 0 })
  const B = ship({ id: 'b-far', x: 90, y: 0 })
  const p = resolveFleetFightPosition({
    fleetId: 'fleet-1',
    encounters: [enc({ engagement_x: 0, engagement_y: 0 })],
    units: [A, B],
    fallback: { x: 200, y: 0 }, // the resting point is nearer B — the ANCHOR must win, not this
  })!
  expect(p.unitId).toBe('a-near-anchor')
  expect({ x: p.x, y: p.y }).toEqual({ x: 10, y: 0 })
})

test('a DEAD enemy stack does not target the badge — it degrades to the anchor rule', () => {
  const A = ship({ id: 'a-near-anchor', x: 10, y: 0 })
  const B = ship({ id: 'b-far', x: 90, y: 0 })
  const deadFoe = unit({ id: 'f-dead', side: 'enemy', alive_count: 0, pos_x: 100, pos_y: 0 })
  const p = resolveFleetFightPosition({
    fleetId: 'fleet-1',
    encounters: [enc({ engagement_x: 0, engagement_y: 0 })],
    units: [A, B, deadFoe],
    fallback: { x: 0, y: 0 },
  })!
  expect(p.unitId).toBe('a-near-anchor') // a live foe at (100,0) would have chosen B
})

test('the anchor is the SERVER’s anchor when it has one, and the resting point when it has not', () => {
  const A = ship({ id: 'a', x: 0, y: 0 })
  const B = ship({ id: 'b', x: 100, y: 0 })
  const withAnchor = resolveFleetFightPosition({
    fleetId: 'fleet-1',
    encounters: [enc({ engagement_x: 100, engagement_y: 0 })],
    units: [A, B],
    fallback: { x: 0, y: 0 },
  })!
  expect(withAnchor.unitId).toBe('b') // the engagement anchor, not the resting point
  const noAnchor = resolveFleetFightPosition({
    fleetId: 'fleet-1',
    encounters: [enc()],
    units: [A, B],
    fallback: { x: 0, y: 0 },
  })!
  expect(noAnchor.unitId).toBe('a') // degrades to the resting point, exactly as the server does
})

// ── ONLY OUR OWN LIVING, POSITIONED, THIS-ENCOUNTER SHIPS ────────────────────────────────────────
test('a destroyed, unpositioned or NaN-positioned ship never takes the badge', () => {
  const intruders = [
    unit({ id: 'a-dead', alive_count: 0, pos_x: ENEMY.x, pos_y: ENEMY.y }), // dead ON the enemy
    unit({ id: 'a-flat', pos_x: null, pos_y: null }),
    unit({ id: 'a-nan', pos_x: Number.NaN, pos_y: ENEMY.y }),
    unit({ id: 'a-inf', pos_x: Number.POSITIVE_INFINITY, pos_y: ENEMY.y }),
  ]
  // each would win outright if it were eligible (ids sort before 'p1-sparrow', positions are on
  // or beside the enemy) — the badge must still be Sparrow V, and never NaN
  const p = at([enc()], [...intruders, ...prodPlayers(), ...prodEnemies()])!
  expect(p.unitId).toBe('p1-sparrow')
  expect({ x: p.x, y: p.y }).toEqual(SPARROW)
  expect(Number.isFinite(p.x) && Number.isFinite(p.y)).toBe(true)
})

test('ANOTHER FLEET’S units never move this fleet’s badge — as ships, or as targets', () => {
  const foreignShip = unit({ id: 'a-foreign', encounter_id: 'e-other', pos_x: ENEMY.x, pos_y: ENEMY.y })
  const foreignEnemy = unit({
    id: 'a-foreign-foe',
    encounter_id: 'e-other',
    side: 'enemy',
    pos_x: -28.6,
    pos_y: 140,
  })
  const p = at([enc()], [...prodPlayers(), ...prodEnemies(), foreignShip, foreignEnemy])!
  // the foreign SHIP does not become the badge, and the foreign ENEMY does not re-aim it at p4-rear
  expect(p.unitId).toBe('p1-sparrow')
  expect({ x: p.x, y: p.y }).toEqual(SPARROW)
})

test('a single ship is the whole formation', () => {
  const p = at([enc()], [ship({ id: 'lone', x: 5, y: -5 }), ...prodEnemies()])!
  expect(p).toEqual({ x: 5, y: -5, source: 'unit', fighting: true, unitId: 'lone' })
})

// ── STABILITY: what the badge does between two 1.5s polls ────────────────────────────────────────
test('STABILITY: the same input always answers the same hull (pure, no hidden state)', () => {
  const units = [...prodPlayers(), ...prodEnemies()]
  const first = at([enc()], units)!
  for (let i = 0; i < 20; i++) expect(at([enc()], units)).toEqual(first)
  // input ORDER is not a hidden input either: the resolver sorts by id before choosing
  expect(at([enc()], [...units].reverse())).toEqual(first)
})

test('STABILITY: an exact tie is broken by unit id, never by array order', () => {
  const foe = unit({ id: 'f', side: 'enemy', pos_x: 0, pos_y: 0 })
  const tie = [ship({ id: 'b-second', x: 0, y: 50 }), ship({ id: 'a-first', x: 50, y: 0 })]
  expect(at([enc()], [...tie, foe])!.unitId).toBe('a-first')
  expect(at([enc()], [...tie.reverse(), foe])!.unitId).toBe('a-first')
})

test('STABILITY: a sub-margin lead does NOT move the badge; a real one does', () => {
  const foe = unit({ id: 'f', side: 'enemy', pos_x: 0, pos_y: 0 })
  const incumbent = ship({ id: 'a-incumbent', x: 50, y: 0 }) // 50.0 out, lowest id
  // a challenger inside the margin: closer, but not by enough to be a different place on screen
  const near = ship({ id: 'b-challenger', x: 50 - (MARGIN - 0.01), y: 0 })
  expect(at([enc()], [incumbent, near, foe])!.unitId).toBe('a-incumbent')
  // a challenger clear of the margin genuinely is the point of attack now
  const far = ship({ id: 'b-challenger', x: 50 - (MARGIN + 0.01), y: 0 })
  expect(at([enc()], [incumbent, far, foe])!.unitId).toBe('b-challenger')
})

test('STABILITY: whoever is chosen is never worse than MARGIN behind the true nearest', () => {
  const foe = unit({ id: 'f', side: 'enemy', pos_x: 0, pos_y: 0 })
  // a long chain of 0.4-unit steps: a "hold unless beaten by the margin" scan would ratchet the
  // badge arbitrarily far back down the line. The choice is measured against the TRUE minimum.
  const chain = Array.from({ length: 12 }, (_, i) => ship({ id: `s${i}`, x: 60 - i * 0.4, y: 0 }))
  const p = at([enc()], [...chain, foe])!
  const chosen = chain.find((u) => u.id === p.unitId)!
  const best = Math.min(...chain.map((u) => u.pos_x as number))
  expect((chosen.pos_x as number) - best).toBeLessThanOrEqual(MARGIN + 1e-9)
})

// ── THE FALLBACK ARM — "exactly today's behaviour" ───────────────────────────────────────────────
test('no encounter at all → the caller’s resting point, not fighting', () => {
  expect(at([], [...prodPlayers(), ...prodEnemies()])).toEqual({
    ...ANCHOR,
    source: 'fallback',
    fighting: false,
    unitId: null,
  })
})

test('an ENDED encounter is not a live fight', () => {
  for (const status of ['escaped', 'defeat', 'completed']) {
    expect(at([enc({ status })], prodPlayers())).toMatchObject({ ...ANCHOR, source: 'fallback', fighting: false })
  }
})

test('another fleet’s encounter is not this fleet’s fight', () => {
  expect(at([enc({ fleet_id: 'fleet-2' })], prodPlayers())).toMatchObject({
    ...ANCHOR,
    source: 'fallback',
    fighting: false,
  })
})

test('TWO live encounters for one fleet (a broken invariant) → resting, never a coin flip', () => {
  expect(at([enc(), enc({ id: 'e2' })], prodPlayers())).toMatchObject({
    ...ANCHOR,
    source: 'fallback',
    fighting: false,
  })
})

test('fighting but UNPOSITIONED (an aggregate fight) rests in place yet still reads as fighting', () => {
  expect(at([enc()], [unit({ pos_x: null, pos_y: null })])).toMatchObject({
    ...ANCHOR,
    source: 'fallback',
    fighting: true,
  })
  expect(at([enc()], [])).toMatchObject({ ...ANCHOR, source: 'fallback', fighting: true })
})

test('a retreating fleet is still being shot at, so it still stands with its lead ship', () => {
  const p = at([enc({ status: 'retreating' })], [...prodPlayers(), ...prodEnemies()])!
  expect({ x: p.x, y: p.y }).toEqual(SPARROW)
  expect(p.fighting).toBe(true)
})

// ── FAIL CLOSED ──────────────────────────────────────────────────────────────────────────────────
test('an unusable FALLBACK is the only null — the caller then draws nothing at all', () => {
  for (const bad of [
    { x: Number.NaN, y: 97 },
    { x: -27, y: Number.NaN },
    { x: Number.POSITIVE_INFINITY, y: 0 },
  ]) {
    expect(at([enc()], [...prodPlayers(), ...prodEnemies()], bad)).toBeNull() // even with a good formation
    expect(at([], [], bad)).toBeNull()
  }
})

test('no fleet id → resting, and never an exception', () => {
  for (const id of [null, undefined, '']) {
    expect(
      resolveFleetFightPosition({ fleetId: id, encounters: [enc()], units: prodPlayers(), fallback: ANCHOR }),
    ).toMatchObject({ ...ANCHOR, source: 'fallback', fighting: false })
  }
})

test('every non-null answer is finite and never silently the origin', () => {
  for (const p of [at([enc()], [...prodPlayers(), ...prodEnemies()]), at([], []), at([enc()], [])]) {
    expect(p).not.toBeNull()
    expect(Number.isFinite(p!.x) && Number.isFinite(p!.y)).toBe(true)
    expect(p!.x === 0 && p!.y === 0).toBe(false)
  }
})

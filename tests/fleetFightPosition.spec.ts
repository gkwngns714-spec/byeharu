import { test, expect } from '@playwright/test'
import { resolveFleetFightPosition } from '../src/features/map/fleetFightPosition'
import { resolveCombatActors } from '../src/features/map/combatActors'
import { resolveFleetPresence } from '../src/features/map/fleetPresence'
import type { CombatUnit } from '../src/features/combat/combatTypes'
import type { FleetEncounterLite } from '../src/features/combat/encounterAnchor'
import type { GroupRow, ShipGroupMapEntry } from '../src/features/command/teamRoster'
import type { FleetPosition } from '../src/features/map/mainshipApi'

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

// ██ "WHEN ENEMY SHIP IS DESTROYED, I TELEPORT TO SOME RANDOM PLACE INSIDE THE ZONE." ██████████████
//
// The owner, playing. It was this file, and it was deterministic: the answer used to be an ARGMIN
// OVER THE LIVING ENEMY SET, and `resolveSpatialUnits` drops a unit the instant `alive_count` hits 0.
// So a kill CHANGED THE TARGET SET, the argmin re-ran, a different hull won, and the fleet's point
// became that other hull's coordinates — in one frame, with nothing tweening across it (combatMotion
// keyframes per unit id, so swapping row A for row B reads B's position directly).
//
// The geometry below is production's: `spatial_formation_ring_radius = 6`, four hulls on the 0336
// ring, `aggro_priority` 100 on exactly ONE of them (0315's elected lead) and 0 on the escorts, with
// two pirates closing on the ring. On that formation the old rule jumped 8.49 world units — an
// opposite ring slot — on a single kill, and again on the kill that cleared the wave.
const RING = 6 // world units — production's spatial_formation_ring_radius, post-0316
const WAVE_ANCHOR = { x: 0, y: 0 } // combat_encounters.engagement_x/y — where the fight started
const LEAD = { x: -RING, y: 0 } // 0315's elected lead, ring slot 2
const RESTING = { x: -100, y: -100 } // the caller's own parked point: never the answer while positioned

/** The largest distance ONE poll may legitimately move a fleet. Production `move_speed` runs 0.2-1.0
 *  world units per 3 s tick and combatMotion plays that step over the tick, so anything beyond this
 *  in a single observation is not motion — it is the badge changing hull, which is the defect. */
const LEGIT_TICK_STEP = 1

const hull = (id: string, x: number, y: number, o: Partial<CombatUnit> = {}): CombatUnit =>
  unit({ id, pos_x: x, pos_y: y, aggro_priority: 0, move_speed: 1, ...o })

/** The four-hull formation: p1 is the elected LEAD, the other three are escorts on the same ring. */
const formation = (o: Partial<CombatUnit> = {}): CombatUnit[] => [
  hull('p1-lead', LEAD.x, LEAD.y, { aggro_priority: 100, ...o }),
  hull('p2-escort', 0, -RING),
  hull('p3-escort', RING, 0),
  hull('p4-escort', 0, RING),
]

/** The pirates, closing on the ring. `alive` names the ones still standing; a killed row KEEPS its
 *  position and drops to alive_count 0, which is exactly the row state production writes. */
const wave = (alive: readonly string[]): CombatUnit[] => [
  unit({ id: 'foe-1', side: 'enemy', aggro_priority: null, pos_x: 2, pos_y: -3, alive_count: alive.includes('foe-1') ? 1 : 0 }),
  unit({ id: 'foe-2', side: 'enemy', aggro_priority: null, pos_x: 3, pos_y: -1, alive_count: alive.includes('foe-2') ? 1 : 0 }),
]

const fightAt = (units: CombatUnit[]) =>
  resolveFleetFightPosition({
    fleetId: 'fleet-1',
    encounters: [enc({ engagement_x: WAVE_ANCHOR.x, engagement_y: WAVE_ANCHOR.y })],
    units,
    fallback: RESTING,
  })!

const step = (a: { x: number; y: number }, b: { x: number; y: number }) => Math.hypot(a.x - b.x, a.y - b.y)

// ── THE REPRODUCTION ─────────────────────────────────────────────────────────────────────────────
test('THE TELEPORT: killing an enemy does not move the fleet — not the first kill, not the last', () => {
  // One wave, killed one pirate at a time, exactly as a fight plays out.
  const both = fightAt([...formation(), ...wave(['foe-1', 'foe-2'])])
  const oneLeft = fightAt([...formation(), ...wave(['foe-1'])]) // foe-2 destroyed
  const cleared = fightAt([...formation(), ...wave([])]) // THE LAST KILL OF THE WAVE

  // Under the old rule these were p3-escort (6,0) → p2-escort (0,-6) → p1-lead (-6,0): two 8.49-unit
  // jumps, one of them fired by the kill that cleared the wave.
  expect(step(both, oneLeft)).toBeLessThanOrEqual(LEGIT_TICK_STEP)
  expect(step(oneLeft, cleared)).toBeLessThanOrEqual(LEGIT_TICK_STEP)
  expect(step(both, cleared)).toBeLessThanOrEqual(LEGIT_TICK_STEP)

  // …because all three answers are the SAME hull: the fleet's own elected lead.
  expect([both.unitId, oneLeft.unitId, cleared.unitId]).toEqual(['p1-lead', 'p1-lead', 'p1-lead'])
  for (const p of [both, oneLeft, cleared]) expect({ x: p.x, y: p.y }).toEqual(LEAD)
})

test('THE LAST KILL OF A WAVE (foes.length === 0) was the worst case — it moves nothing now', () => {
  // With no living enemy the old rule switched its TARGET to the engagement anchor, flipping the
  // badge from the hull furthest forward to the hull nearest where the fight started. Every hull here
  // is exactly RING from that anchor, so the old tie-break handed it to a different ship outright.
  const before = fightAt([...formation(), ...wave(['foe-1'])])
  const after = fightAt([...formation(), ...wave([])])
  expect(step(before, after)).toBe(0)
  expect(after.unitId).toBe('p1-lead')
  expect(after.source).toBe('unit')
  expect(after.fighting).toBe(true)
})

test('THE ENEMY SET IS NOT AN INPUT: move the pirates anywhere, the fleet does not follow', () => {
  const anchored = fightAt([...formation(), ...wave(['foe-1', 'foe-2'])])
  // the same fight with the pirates on the far side of the formation, and with none at all
  const flipped = [
    unit({ id: 'foe-1', side: 'enemy', aggro_priority: null, pos_x: -2, pos_y: 300 }),
    unit({ id: 'foe-2', side: 'enemy', aggro_priority: null, pos_x: 3, pos_y: 301 }),
  ]
  expect(fightAt([...formation(), ...flipped])).toEqual(anchored)
  expect(fightAt([...formation()])).toEqual(anchored)
})

// ── THE FALLBACK ARM: the lead is gone ───────────────────────────────────────────────────────────
test('LEAD IS DEAD → the old nearest-the-enemy rule, still a REAL hull of ours', () => {
  const rows = [...formation({ alive_count: 0, hp_current: 0 }), ...wave(['foe-1', 'foe-2'])]
  const p = fightAt(rows)
  expect(p.unitId).toBe('p3-escort') // 3.16 from foe-2; p2-escort is 3.61 from foe-1
  expect({ x: p.x, y: p.y }).toEqual({ x: RING, y: 0 })
  // MEMBERSHIP survives on the fallback arm: it is one of the input rows, not a point between them.
  expect(positionsOf(rows.filter((r) => r.side === 'player' && r.alive_count > 0))).toContain(`${p.x},${p.y}`)
})

test('LEAD IS UNPOSITIONED → the fallback arm too (never a NaN, never a guessed point)', () => {
  const p = fightAt([...formation({ pos_x: null, pos_y: null }), ...wave(['foe-1', 'foe-2'])])
  expect(p.unitId).toBe('p3-escort')
  expect(Number.isFinite(p.x) && Number.isFinite(p.y)).toBe(true)
})

test('NO LEAD ELECTED AT ALL (aggro_priority null on every hull) → the fallback arm', () => {
  const p = fightAt([
    ...formation().map((u) => ({ ...u, aggro_priority: null })),
    ...wave(['foe-1', 'foe-2']),
  ])
  expect(p.unitId).toBe('p3-escort')
})

test('the lead is the SERVER’s election, not a client-side guess at the biggest or nearest hull', () => {
  // The elected lead is the SMALLEST hull and the one FURTHEST from the enemy. Neither fact moves the
  // badge: only `aggro_priority` does, because only the server writes it (0315).
  const rows = [
    hull('a-huge-and-nearest', 3, -2, { hp_max: 9000, aggro_priority: 0 }),
    hull('z-the-lead', 400, 400, { hp_max: 10, aggro_priority: 100 }),
    ...wave(['foe-1', 'foe-2']),
  ]
  const p = fightAt(rows)
  expect(p.unitId).toBe('z-the-lead')
  expect({ x: p.x, y: p.y }).toEqual({ x: 400, y: 400 })
})

test('STABILITY: the lead arm is a pure function of the rows, and order is not an input', () => {
  const rows = [...formation(), ...wave(['foe-1', 'foe-2'])]
  const first = fightAt(rows)
  for (let i = 0; i < 20; i++) expect(fightAt(rows)).toEqual(first)
  expect(fightAt([...rows].reverse())).toEqual(first)
})

// ── ONE POSITION, TWO CALLERS — THEY MOVE TOGETHER BY CONSTRUCTION ───────────────────────────────
// The fleet's combat GLYPH (combatActors) and its named BADGE (fleetPresence) both ask this one
// authority. "The same fleet, rendered twice, in two places" is the defect at the top of this file;
// this spec is what stops a future change giving either caller a rule of its own.
const G1: GroupRow = { group_id: 'g1', group_index: 1, name: 'Alpha' }
const MEMBERSHIP: Record<string, Pick<ShipGroupMapEntry, 'group_id'>> = { s1: { group_id: 'g1' } }
const PARKED: Pick<FleetPosition, 'main_ship_id' | 'place' | 'location_id' | 'segment' | 'space_x' | 'space_y'> = {
  main_ship_id: 's1',
  place: 'in_space',
  location_id: null,
  segment: null,
  space_x: RESTING.x,
  space_y: RESTING.y,
}

const badgeAt = (units: CombatUnit[]) => {
  const out = resolveFleetPresence({
    groups: [G1],
    membership: MEMBERSHIP,
    positions: [PARKED],
    fleets: [{ id: 'fleet-1', group_id: 'g1' }],
    encounters: [enc({ engagement_x: WAVE_ANCHOR.x, engagement_y: WAVE_ANCHOR.y })],
    units,
    nowMs: 0,
  })
  expect(out).toHaveLength(1)
  expect(out[0].state).toBe('in-combat')
  return out[0].at!
}

const glyphAt = (units: CombatUnit[]) => {
  const fleet = resolveCombatActors(units, [enc({ engagement_x: WAVE_ANCHOR.x, engagement_y: WAVE_ANCHOR.y })]).find(
    (a) => a.side === 'player',
  )!
  return { x: fleet.x, y: fleet.y }
}

test('the GLYPH and the BADGE stand on the same point, through every state of the wave', () => {
  for (const alive of [['foe-1', 'foe-2'], ['foe-1'], ['foe-2'], []]) {
    const rows = [...formation(), ...wave(alive)]
    const authority = fightAt(rows)
    expect(glyphAt(rows)).toEqual({ x: authority.x, y: authority.y })
    expect(badgeAt(rows)).toEqual({ x: authority.x, y: authority.y })
    // and neither of them teleported as the wave was cleared
    expect({ x: authority.x, y: authority.y }).toEqual(LEAD)
  }
})

test('the GLYPH and the BADGE follow the fleet together when the LEAD itself moves', () => {
  // The one motion that MAY move the marker: the lead's own row moving, by one legitimate step.
  const moved = formation().map((u) => (u.id === 'p1-lead' ? { ...u, pos_x: LEAD.x + 0.4, pos_y: LEAD.y } : u))
  const rows = [...moved, ...wave(['foe-1', 'foe-2'])]
  const authority = fightAt(rows)
  expect(step(authority, LEAD)).toBeCloseTo(0.4, 12)
  expect(step(authority, LEAD)).toBeLessThanOrEqual(LEGIT_TICK_STEP)
  expect(glyphAt(rows)).toEqual({ x: authority.x, y: authority.y })
  expect(badgeAt(rows)).toEqual({ x: authority.x, y: authority.y })
})

import { test, expect } from '@playwright/test'
import { resolveCombatActors } from '../src/features/map/combatActors'
import { resolveRenderPoints, resolveHitSplats, spatialCombatLayer } from '../src/features/map/spatialCombatLayer'
import type { CombatEncounter, CombatEvent, CombatUnit } from '../src/features/combat/combatTypes'

// THE FLEET IS THE COMBAT ACTOR — the pure proof of the fold.
//
// The owner: "why are there four ships? because i have 4 ships in fleet? no, show only fleet. it is
// as a whole." `combat_units` is one row per ship — four of them on the owner's own production
// encounters — and the map drew one glyph each. These specs pin that ONE glyph is drawn for a fleet
// of ANY size, that the fold never flatters the fleet's condition, and that folding did not hide a
// loss, a shot or a damage number.
//
// NO AMBIENT PRECONDITIONS: every fixture states its own positions, hp, liveness and encounter.

const norm = (p: { x: number; y: number }) => p

const unit = (o: Partial<CombatUnit> & { id: string }): CombatUnit => ({
  encounter_id: 'e1',
  unit_type_id: null,
  main_ship_id: `ship-${o.id}`,
  ship_hp: 100,
  initial_count: 1,
  alive_count: 1,
  hp_max: 100,
  hp_current: 100,
  pos_x: 0,
  pos_y: 0,
  move_speed: 4,
  side: 'player',
  aggro_priority: 0,
  weapons_json: [{ module_type_id: 'autocannon_battery', range: 5, projectile_speed: 60, power: 10 }],
  ...o,
})

const encounter = (o: Partial<CombatEncounter> = {}): CombatEncounter =>
  ({
    id: 'e1',
    player_id: 'p',
    fleet_id: 'fleet-1',
    presence_id: 'pres-1',
    location_id: 'loc-1',
    status: 'active',
    tick_number: 7,
    danger_level: 1,
    waves_cleared: 0,
    player_power_start: 1,
    player_power_current: 1,
    enemy_power_current: 1,
    player_integrity_max: 1,
    player_integrity_current: 1,
    enemy_integrity_max: 1,
    enemy_integrity_current: 1,
    wave_number: 1,
    next_wave_at: null,
    total_rewards_json: {},
    started_at: '2026-08-03T12:00:00Z',
    retreat_started_at: null,
    ended_at: null,
    engagement_x: 0,
    engagement_y: 0,
    ...o,
  }) as CombatEncounter

/** A fleet of N hulls in a ring, plus one hostile to give the fight a target. */
const fleetOf = (n: number, hulls: Partial<CombatUnit>[] = []): CombatUnit[] => [
  ...Array.from({ length: n }, (_, i) =>
    unit({ id: `p${i}`, pos_x: 10 * Math.cos(i), pos_y: 10 * Math.sin(i), ...hulls[i] }),
  ),
  unit({ id: 'foe', side: 'enemy', aggro_priority: null, pos_x: 40, pos_y: 0 }),
]

const dmg = (o: Partial<CombatEvent> & { id: number }): CombatEvent => ({
  encounter_id: 'e1',
  tick_number: 7,
  seq: 0,
  event_type: 'hull_damage',
  source: 'pirate',
  target: 'player',
  projectile_type: null,
  projectile_count: null,
  impact_delay_ms: null,
  payload_json: {},
  created_at: '2026-08-03T12:00:00Z',
  ...o,
})

// ── THE PROOF: ONE GLYPH PER FLEET, FOR EVERY N ───────────────────────────────────────────────────

for (const n of [1, 2, 3, 4, 5, 8, 12]) {
  test(`THE PROOF — a fleet of ${n} ship(s) renders exactly ONE combat glyph`, () => {
    const rows = fleetOf(n)
    const actors = resolveCombatActors(rows, [encounter()])
    const fleets = actors.filter((a) => a.side === 'player')
    expect(fleets).toHaveLength(1)
    expect(fleets[0].kind).toBe('fleet')
    expect(fleets[0].ships).toBe(n)
    expect(fleets[0].shipsAlive).toBe(n)
    expect(fleets[0].unitIds).toHaveLength(n)

    // …and the RENDERED tree carries exactly one player glyph, whatever N is. A change that brings
    // per-ship glyphs back fails here, not in a screenshot.
    const els = spatialCombatLayer({ actors, units: rows, events: [], norm, k: 1 })
    const glyphs = els.filter(
      (e) =>
        String((e.props as Record<string, unknown>)['data-testid'] ?? '').startsWith('spatial-combat-unit-') &&
        (e.props as Record<string, unknown>)['data-side'] === 'player',
    )
    expect(glyphs).toHaveLength(1)
    expect((glyphs[0].props as Record<string, unknown>)['data-kind']).toBe('fleet')
  })
}

test('the fleet glyph STANDS ON A REAL SHIP — the same point fleetFightPosition gives its badge', () => {
  // resolveFleetFightPosition's rule: our own living hull NEAREST the enemy. p1 is that hull here.
  const rows = [
    unit({ id: 'p0', pos_x: 0, pos_y: 0 }),
    unit({ id: 'p1', pos_x: 30, pos_y: 0 }),
    unit({ id: 'foe', side: 'enemy', aggro_priority: null, pos_x: 40, pos_y: 0 }),
  ]
  const fleet = resolveCombatActors(rows, [encounter()]).find((a) => a.side === 'player')!
  expect({ x: fleet.x, y: fleet.y }).toEqual({ x: 30, y: 0 })
  // A MEMBER of the input set, never a mean: (0+30)/2 = 15 is what a centroid would have said.
  expect(rows.some((r) => r.pos_x === fleet.x && r.pos_y === fleet.y)).toBe(true)
})

test('with NO encounter row in hand the fleet still stands on one of its own hulls', () => {
  const rows = fleetOf(3)
  const fleet = resolveCombatActors(rows, []).find((a) => a.side === 'player')!
  expect(rows.some((r) => r.side === 'player' && r.pos_x === fleet.x && r.pos_y === fleet.y)).toBe(true)
})

// ── THE FOLD NEVER FLATTERS ───────────────────────────────────────────────────────────────────────

test('a fleet that has LOST a ship cannot read as untouched', () => {
  const whole = resolveCombatActors(fleetOf(4), [encounter()]).find((a) => a.side === 'player')!
  const bereaved = resolveCombatActors(
    fleetOf(4, [{}, {}, {}, { alive_count: 0, hp_current: 0 }]),
    [encounter()],
  ).find((a) => a.side === 'player')!
  expect(whole.hpFrac).toBe(1)
  expect(bereaved.hpFrac).toBeCloseTo(0.75, 12) // the dead hull's FULL max still counts
  expect(bereaved.shipsAlive).toBe(3)
  expect(bereaved.ships).toBe(4) // and the loss is stated, not only implied by the bar
})

test('the aggregate is never HEALTHIER than the fleet’s own summed truth', () => {
  // Three untouched hulls and one at 4%. A "worst hull" reading would say 4%, a mean of fractions
  // would say 76%; the sum says 76% too, but the point is that it is bounded by the real total and
  // moves the instant any hull is hurt — it can never be 100% while a hull is hurt.
  const rows = fleetOf(4, [{ hp_current: 4 }])
  const fleet = resolveCombatActors(rows, [encounter()]).find((a) => a.side === 'player')!
  const summedNow = 4 + 100 + 100 + 100
  const summedMax = 400
  expect(fleet.hpFrac).toBeCloseTo(summedNow / summedMax, 12)
  expect(fleet.hpFrac).toBeLessThan(1)
})

test('a fleet with every hull destroyed draws NO glyph, but is still an anchor for the last blow', () => {
  const rows = fleetOf(2, [{ alive_count: 0, hp_current: 0 }, { alive_count: 0, hp_current: 0 }])
  const fleet = resolveCombatActors(rows, [encounter()]).find((a) => a.side === 'player')!
  expect(fleet.alive).toBe(false)
  expect(fleet.hpFrac).toBe(0)
  const els = spatialCombatLayer({ actors: resolveCombatActors(rows, [encounter()]), units: rows, events: [], norm, k: 1 })
  expect(
    els.filter((e) => String((e.props as Record<string, unknown>)['data-testid'] ?? '') === `spatial-combat-unit-${fleet.key}`),
  ).toHaveLength(0)
  // …and its splat anchor survives, so the killing blow still lands somewhere visible.
  const splats = resolveHitSplats(
    [dmg({ id: 1, payload_json: { unit_id: 'p0', damage: 12 } })],
    resolveRenderPoints(resolveCombatActors(rows, [encounter()])),
  )
  expect(splats).toHaveLength(1)
})

test('the fleet’s reach is the reach of the hulls STILL ALIVE', () => {
  const rows = fleetOf(3, [
    { weapons_json: [{ module_type_id: 'g', range: 4, projectile_speed: 60, power: 1 }] },
    { weapons_json: [{ module_type_id: 'g', range: 9, projectile_speed: 60, power: 1 }], alive_count: 0, hp_current: 0 },
    { weapons_json: [{ module_type_id: 'g', range: 6, projectile_speed: 60, power: 1 }] },
  ])
  const fleet = resolveCombatActors(rows, [encounter()]).find((a) => a.side === 'player')!
  expect(fleet.range).toBe(6) // the dead hull's 9 is not a reach the fleet has
})

// ── THE ENEMY SIDE IS NOT FOLDED ──────────────────────────────────────────────────────────────────

test('enemies stay one glyph EACH — how many are still shooting is the player’s read', () => {
  const rows = [
    unit({ id: 'p0' }),
    unit({ id: 'e1', side: 'enemy', aggro_priority: null, pos_x: 40 }),
    unit({ id: 'e2', side: 'enemy', aggro_priority: null, pos_x: 45 }),
    unit({ id: 'e3', side: 'enemy', aggro_priority: null, pos_x: 50 }),
  ]
  const actors = resolveCombatActors(rows, [encounter()])
  expect(actors.filter((a) => a.side === 'enemy')).toHaveLength(3)
  expect(actors.filter((a) => a.side === 'enemy').every((a) => a.kind === 'unit')).toBe(true)
  expect(actors.filter((a) => a.side === 'player')).toHaveLength(1)
})

test('a destroyed enemy draws no glyph — but stays an anchor, so its killing blow still lands', () => {
  const rows = [
    unit({ id: 'p0' }),
    unit({ id: 'e1', side: 'enemy', aggro_priority: null, pos_x: 40 }),
    unit({ id: 'e2', side: 'enemy', aggro_priority: null, pos_x: 45, alive_count: 0, hp_current: 0 }),
  ]
  const actors = resolveCombatActors(rows, [encounter()])
  // The pack the player still has to fight is the LIVING one — that is what the glyph pass draws.
  expect(actors.filter((a) => a.side === 'enemy' && a.alive).map((a) => a.key)).toEqual(['unit-e1'])
  const els = spatialCombatLayer({ actors, units: rows, events: [], norm, k: 1 })
  expect(els.some((e) => (e.props as Record<string, unknown>)['data-testid'] === 'spatial-combat-unit-unit-e2')).toBe(false)
  // …and the wreck keeps its point, so the number that killed it is not silently dropped.
  const splats = resolveHitSplats(
    [dmg({ id: 1, payload_json: { unit_id: 'e2', damage: 9 } })],
    resolveRenderPoints(actors),
  )
  expect(splats).toHaveLength(1)
  expect(splats[0]).toMatchObject({ x: 45, damage: 9 })
})

// ── TWO FIGHTS ARE TWO FLEETS ─────────────────────────────────────────────────────────────────────

test('two simultaneous battles are two fleet glyphs, never one merged blob', () => {
  const rows = [
    unit({ id: 'a1', encounter_id: 'e1', pos_x: 0 }),
    unit({ id: 'a2', encounter_id: 'e1', pos_x: 5 }),
    unit({ id: 'b1', encounter_id: 'e2', pos_x: 900 }),
  ]
  const actors = resolveCombatActors(rows, [encounter(), encounter({ id: 'e2', fleet_id: 'fleet-2' })])
  expect(actors.filter((a) => a.kind === 'fleet').map((a) => a.key).sort()).toEqual(['fleet-e1', 'fleet-e2'])
})

// ── THE FOLD LOSES NOTHING ────────────────────────────────────────────────────────────────────────

test('every hull’s damage still shows — four ships’ numbers land on one glyph, fanned apart', () => {
  const rows = fleetOf(4)
  const points = resolveRenderPoints(resolveCombatActors(rows, [encounter()]))
  const splats = resolveHitSplats(
    [
      dmg({ id: 1, seq: 0, payload_json: { unit_id: 'p0', damage: 3 } }),
      dmg({ id: 2, seq: 1, payload_json: { unit_id: 'p1', damage: 5 } }),
      dmg({ id: 3, seq: 2, payload_json: { unit_id: 'p2', damage: 7 } }),
    ],
    points,
  )
  expect(splats.map((s) => s.damage)).toEqual([3, 5, 7]) // no number is lost to the fold
  expect(splats.map((s) => s.unitId)).toEqual(['p0', 'p1', 'p2']) // and each still names its hull
  // Fanned by the GLYPH they land on, so three numbers do not stack at one point.
  expect(splats.map((s) => s.index)).toEqual([0, 1, 2])
  expect(splats.every((s) => s.count === 3)).toBe(true)
  // All three float over the same, single fleet glyph.
  expect(new Set(splats.map((s) => `${s.x},${s.y}`)).size).toBe(1)
})

test('every unit of a fleet resolves to the SAME render point — one glyph, one place', () => {
  const rows = fleetOf(4)
  const points = resolveRenderPoints(resolveCombatActors(rows, [encounter()]))
  const ours = rows.filter((r) => r.side === 'player').map((r) => points.get(r.id)!)
  expect(new Set(ours.map((p) => p.key)).size).toBe(1)
  expect(new Set(ours.map((p) => `${p.x},${p.y}`)).size).toBe(1)
  // …while the hostile keeps its own.
  expect(points.get('foe')!.key).toBe('unit-foe')
})

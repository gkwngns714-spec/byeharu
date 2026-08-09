import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  STEP_DEFAULT_MS,
  STEP_MAX_MS,
  STEP_MIN_MS,
  SHOT_MAX_MS,
  SHOT_MIN_MS,
  anyTickArtifactLive,
  anyUnitInMotion,
  motionPoint,
  observeCombatUnits,
  observeCombatEvents,
  isTickArtifact,
  tickArtifactLive,
  TICK_READOUT_MS,
  resolveEncounterLead,
  resolveOrdnance,
  resolveOrdnanceProfile,
  resolveShotArrivals,
  smoothCombatUnits,
  type CombatMotion,
  type ShotEndpoint,
} from '../src/features/map/combatMotion'
import {
  interpolateMovementPoint,
  interpolateSegment,
  movementProgress,
  segmentProgress,
} from '../src/features/map/movementInterpolation'
import { latestTickByEncounter, isSpatialSalvo } from '../src/features/map/spatialCombatLayer'
import type { CombatEvent, CombatUnit } from '../src/features/combat/combatTypes'

// COMBAT THAT FLOWS — the pure proof for the motion layer.
//
// NO WALL CLOCK ANYWHERE IN THIS FILE. Every function under test takes `nowMs` as an argument and
// every call below passes an explicit one, so a run is deterministic and a `Date.now()` read during
// render cannot creep back in unnoticed (an earlier slice shipped exactly that impurity).
//
// NO AMBIENT PRECONDITIONS. Every fixture states its own positions, timestamps, weapons and
// aggro_priority. Nothing here asserts a seeded world, a default tick length, or a catalog value —
// where the server's real numbers matter (a 3 s tick, a 100 ms impact delay) they are supplied as
// data, not assumed to be present.

const T0 = 1_000_000 // an arbitrary but explicit client clock origin

const unit = (o: Partial<CombatUnit> = {}): CombatUnit => ({
  id: 'u1',
  encounter_id: 'e1',
  unit_type_id: null,
  main_ship_id: 'ship-1',
  ship_hp: 100,
  initial_count: 1,
  alive_count: 1,
  hp_max: 100,
  hp_current: 100,
  pos_x: 0,
  pos_y: 0,
  move_speed: 5,
  side: 'player',
  aggro_priority: 0,
  updated_at: '2026-08-03T15:51:00.000Z',
  weapons_json: [{ module_type_id: 'autocannon_battery', range: 5, projectile_speed: 60, power: 10 }],
  ...o,
})

const salvo = (o: Partial<CombatEvent> = {}): CombatEvent => ({
  id: 1,
  encounter_id: 'e1',
  tick_number: 7,
  seq: 0,
  event_type: 'missile_salvo',
  source: 'player',
  target: 'pirate',
  projectile_type: 'autocannon_battery',
  projectile_count: 1,
  impact_delay_ms: 100,
  payload_json: { unit_id: 'u1', target_id: 'u2' },
  created_at: '2026-08-03T15:51:00.000Z',
  ...o,
})

const hit = (o: Partial<CombatEvent> = {}): CombatEvent =>
  salvo({ id: 2, seq: 1, event_type: 'hull_damage', payload_json: { unit_id: 'u2', damage: 4 }, ...o })

// Two consecutive server ticks, 3.0 s apart — production's measured cadence (3014-3042 ms), stated
// here as data rather than relied on as a default.
const TICK_A = '2026-08-03T15:51:00.000Z'
const TICK_B = '2026-08-03T15:51:03.000Z'

// ── THE GENERALISED PRIMITIVE — one lerp, two shapes of caller ─────────────────────────────────────

test('segmentProgress: clamped to [0,1] — never before the start, never past the end', () => {
  const seg = { fromX: 0, fromY: 0, toX: 10, toY: 0, startMs: 100, endMs: 200 }
  expect(segmentProgress(seg, 50)).toBe(0)
  expect(segmentProgress(seg, 150)).toBeCloseTo(0.5, 12)
  expect(segmentProgress(seg, 100_000)).toBe(1)
})

test('segmentProgress: a zero-length window is a segment ALREADY FINISHED (progress 1)', () => {
  // This is what "a unit that has just appeared is AT its position" is expressed as.
  expect(segmentProgress({ fromX: 3, fromY: 4, toX: 3, toY: 4, startMs: 500, endMs: 500 }, 0)).toBe(1)
})

test('segmentProgress: a reversed window or a non-finite bound yields null, never a guess', () => {
  expect(segmentProgress({ fromX: 0, fromY: 0, toX: 1, toY: 1, startMs: 200, endMs: 100 }, 150)).toBeNull()
  expect(segmentProgress({ fromX: 0, fromY: 0, toX: 1, toY: 1, startMs: NaN, endMs: 100 }, 50)).toBeNull()
})

test('interpolateSegment: a non-finite endpoint draws nothing rather than NaN into an SVG attribute', () => {
  expect(
    interpolateSegment({ fromX: Number.NaN, fromY: 0, toX: 10, toY: 0, startMs: 0, endMs: 10 }, 5),
  ).toBeNull()
})

test('the ISO movement adapters keep their OWN stricter contract: arrive_at <= depart_at → null', () => {
  // The primitive accepts endMs === startMs; a fleet_movements row with no duration is incoherent
  // and must still draw nothing. Proving both rules coexist is the point of this case.
  const bad = {
    origin_x: 0,
    origin_y: 0,
    target_x: 10,
    target_y: 10,
    depart_at: '2026-08-03T00:00:00Z',
    arrive_at: '2026-08-03T00:00:00Z',
  }
  expect(interpolateMovementPoint(bad, Date.parse('2026-08-03T00:00:00Z'))).toBeNull()
  expect(movementProgress(bad, Date.parse('2026-08-03T00:00:00Z'))).toBeNull()
})

test('fleet travel is unchanged by the generalisation: halfway is halfway', () => {
  const seg = {
    origin_x: 100,
    origin_y: 200,
    target_x: 300,
    target_y: 600,
    depart_at: '2026-08-03T00:00:00Z',
    arrive_at: '2026-08-03T00:00:10Z',
  }
  const mid = Date.parse('2026-08-03T00:00:05Z')
  expect(interpolateMovementPoint(seg, mid)).toEqual({ x: 200, y: 400 })
  expect(movementProgress(seg, mid)).toBeCloseTo(0.5, 12)
})

// ── THE PROOF: a step is CROSSED, strictly between two observed points, monotonic in t ─────────────

test('THE PROOF — between two ticks a unit is strictly between its two OBSERVED positions, and monotonic', () => {
  const at = (x: number, updated: string) => [unit({ id: 'a', pos_x: x, pos_y: 0, updated_at: updated })]

  // Observation 1: the unit is at x=0. Observation 2, one 3 s server tick later: x=30.
  let m: CombatMotion = observeCombatUnits({}, at(0, TICK_A), T0)
  m = observeCombatUnits(m, at(30, TICK_B), T0 + 1500)

  const step = m['a']
  expect(step.fromX).toBe(0) // the PREVIOUS OBSERVATION, not a mid-tween point
  expect(step.toX).toBe(30)
  expect(step.endMs - step.startMs).toBe(3000) // the server's own measured interval, not a constant

  // Sample the whole window. Every sample lies strictly inside (0,30) and never decreases.
  let prev = -Infinity
  for (let i = 1; i < 40; i++) {
    const t = step.startMs + (i * (step.endMs - step.startMs)) / 40
    const p = motionPoint(m, 'a', t)!
    expect(p.x).toBeGreaterThan(0)
    expect(p.x).toBeLessThan(30)
    expect(p.x).toBeGreaterThan(prev) // strictly monotonic in t
    prev = p.x
  }
  // The ends are exactly the two observations — it starts where it was and finishes where it is.
  expect(motionPoint(m, 'a', step.startMs)).toEqual({ x: 0, y: 0 })
  expect(motionPoint(m, 'a', step.endMs)).toEqual({ x: 30, y: 0 })
})

test('NO EXTRAPOLATION — past the window the unit holds its latest observed position forever', () => {
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0, updated_at: TICK_A })], T0)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 30, updated_at: TICK_B })], T0)
  expect(motionPoint(m, 'a', T0 + 3000)).toEqual({ x: 30, y: 0 })
  expect(motionPoint(m, 'a', T0 + 9_000_000)).toEqual({ x: 30, y: 0 })
})

// ── THE ANTI-PROOFS ───────────────────────────────────────────────────────────────────────────────

test('ANTI-PROOF: a SPAWN is not tweened — a unit seen for the first time is AT its position', () => {
  const m = observeCombatUnits({}, [unit({ id: 'new', pos_x: 42, pos_y: -7 })], T0)
  expect(m['new'].startMs).toBe(m['new'].endMs) // a zero-length window: nothing to play
  expect(motionPoint(m, 'new', T0)).toEqual({ x: 42, y: -7 })
  expect(motionPoint(m, 'new', T0 - 5000)).toEqual({ x: 42, y: -7 })
  expect(motionPoint(m, 'new', T0 + 5000)).toEqual({ x: 42, y: -7 })
})

test('ANTI-PROOF: a spawn NEXT TO an existing fight is not tweened in from another ship', () => {
  // An enemy wave arriving mid-battle must appear where it spawns, not slide in from a neighbour.
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0 })], T0)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 0 }), unit({ id: 'wave2', pos_x: 500, pos_y: 500 })], T0 + 1500)
  expect(motionPoint(m, 'wave2', T0 + 1500)).toEqual({ x: 500, y: 500 })
  expect(motionPoint(m, 'wave2', T0 + 3000)).toEqual({ x: 500, y: 500 })
})

test('ANTI-PROOF: a STOPPED unit does not drift — an unchanged position never restarts a tween', () => {
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0, updated_at: TICK_A })], T0)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 30, updated_at: TICK_B })], T0)
  const arrived = { ...m['a'] }
  // Three further polls, all reporting the SAME position (the ship is holding station).
  for (let i = 1; i <= 3; i++) {
    m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 30, updated_at: TICK_B })], T0 + i * 1500)
  }
  expect(m['a'].fromX).toBe(arrived.fromX)
  expect(m['a'].toX).toBe(30)
  expect(m['a'].startMs).toBe(arrived.startMs) // the window was NOT reopened
  expect(m['a'].endMs).toBe(arrived.endMs)
  for (const t of [T0 + 3000, T0 + 6000, T0 + 60_000]) {
    expect(motionPoint(m, 'a', t)).toEqual({ x: 30, y: 0 })
  }
})

test('ANTI-PROOF: a DEATH is not tweened — a row that leaves the set is dropped, not glided', () => {
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0 }), unit({ id: 'doomed', pos_x: 90 })], T0)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 0 })], T0 + 1500)
  expect(m['doomed']).toBeUndefined()
  expect(motionPoint(m, 'doomed', T0 + 1500)).toBeNull() // nothing to draw a path from
})

test('ANTI-PROOF: a DEAD-but-still-positioned unit is not tweened either — a wreck holds its point', () => {
  // 0299 leaves a destroyed row positioned so the killing blow has somewhere to land. It must not
  // then slide: its position stops changing, so the "stopped" rule already covers it.
  let m = observeCombatUnits({}, [unit({ id: 'd', pos_x: 12, alive_count: 1 })], T0)
  m = observeCombatUnits(m, [unit({ id: 'd', pos_x: 12, alive_count: 0 })], T0 + 1500)
  expect(motionPoint(m, 'd', T0 + 9000)).toEqual({ x: 12, y: 0 })
})

test('an id that comes back after leaving is a SPAWN again, never a tween across the gap', () => {
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0 })], T0)
  m = observeCombatUnits(m, [], T0 + 1500)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 900 })], T0 + 3000)
  expect(m['a'].startMs).toBe(m['a'].endMs)
  expect(motionPoint(m, 'a', T0 + 3000)).toEqual({ x: 900, y: 0 })
})

test('a row with no position is not tracked at all — the dark path stays dark', () => {
  const m = observeCombatUnits({}, [unit({ id: 'aggregate', pos_x: null, pos_y: null })], T0)
  expect(Object.keys(m)).toHaveLength(0)
})

// ── THE MEASURED STEP DURATION ────────────────────────────────────────────────────────────────────

test('the step is played over the SERVER’s own measured interval, not a client constant', () => {
  // A deliberately non-3 s cadence: if the client were assuming 3000 this would come back 3000.
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0, updated_at: '2026-08-03T10:00:00.000Z' })], T0)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 5, updated_at: '2026-08-03T10:00:01.250Z' })], T0)
  expect(m['a'].endMs - m['a'].startMs).toBe(1250)
})

test('an unusable server timestamp falls back to the STATED default, never to NaN', () => {
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0, updated_at: null })], T0)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 5, updated_at: null })], T0)
  expect(m['a'].endMs - m['a'].startMs).toBe(STEP_DEFAULT_MS)
})

test('a broken cadence is CLAMPED, so a step never flashes and never crawls', () => {
  // A stalled cron: the previous tick was ten minutes ago. The ship still crosses in one plausible
  // step rather than creeping for ten minutes.
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0, updated_at: '2026-08-03T10:00:00.000Z' })], T0)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 5, updated_at: '2026-08-03T10:10:00.000Z' })], T0)
  expect(m['a'].endMs - m['a'].startMs).toBe(STEP_MAX_MS)

  // And a 12 ms gap (two writes inside one tick) does not become a teleport with a 12 ms window.
  let n = observeCombatUnits({}, [unit({ id: 'b', pos_x: 0, updated_at: '2026-08-03T10:00:00.000Z' })], T0)
  n = observeCombatUnits(n, [unit({ id: 'b', pos_x: 5, updated_at: '2026-08-03T10:00:00.012Z' })], T0)
  expect(n['b'].endMs - n['b'].startMs).toBe(STEP_MIN_MS)
})

test('a LONG reposition is played out in full — the smoothing assumes no maximum step size', () => {
  // slice-reposition-is-a-move turns an in-combat reposition into a real move over several ticks.
  // Each of its ticks is an ordinary observed step, however far it goes.
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0, pos_y: 0, updated_at: TICK_A })], T0)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 4000, pos_y: -2500, updated_at: TICK_B })], T0)
  const half = motionPoint(m, 'a', T0 + 1500)!
  expect(half.x).toBeCloseTo(2000, 6)
  expect(half.y).toBeCloseTo(-1250, 6)
  expect(motionPoint(m, 'a', T0 + 3000)).toEqual({ x: 4000, y: -2500 })
})

// ── THE ROWS, NOT THE GLYPHS ──────────────────────────────────────────────────────────────────────

test('smoothCombatUnits moves the ROWS, so every consumer of resolveSpatialUnits agrees', () => {
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0, updated_at: TICK_A })], T0)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 30, updated_at: TICK_B })], T0)
  const [row] = smoothCombatUnits([unit({ id: 'a', pos_x: 30 })], m, T0 + 1500)
  expect(row.pos_x).toBeCloseTo(15, 6)
  // Everything else about the row is untouched — this moves a position, it does not reshape a row.
  expect(row.id).toBe('a')
  expect(row.hp_current).toBe(100)
  expect(row.alive_count).toBe(1)
})

test('smoothCombatUnits passes an unpositioned row through UNTOUCHED (identity)', () => {
  const rows = [unit({ id: 'x', pos_x: null, pos_y: null })]
  expect(smoothCombatUnits(rows, {}, T0)[0]).toBe(rows[0])
})

test('smoothCombatUnits keeps the SERVER position when it has no keyframe — never a guess', () => {
  const rows = [unit({ id: 'untracked', pos_x: 77, pos_y: 88 })]
  const out = smoothCombatUnits(rows, {}, T0)
  expect(out[0].pos_x).toBe(77)
  expect(out[0].pos_y).toBe(88)
})

test('anyUnitInMotion is the frame loop’s stop condition: false once the last step has landed', () => {
  let m = observeCombatUnits({}, [unit({ id: 'a', pos_x: 0, updated_at: TICK_A })], T0)
  m = observeCombatUnits(m, [unit({ id: 'a', pos_x: 30, updated_at: TICK_B })], T0)
  expect(anyUnitInMotion(m, T0 + 1500)).toBe(true)
  expect(anyUnitInMotion(m, T0 + 3000)).toBe(false)
  expect(anyUnitInMotion({}, T0)).toBe(false)
})

// ── THE ELECTED LEAD (0315), COMPOSED — NOT RE-DERIVED ────────────────────────────────────────────

test('the lead is the row the SERVER marked — aggro_priority 100, not a client-side command-ship rule', () => {
  const units = [
    unit({ id: 'escort-a', aggro_priority: 0, hp_max: 900 }), // the biggest hull: NOT the lead
    unit({ id: 'the-lead', aggro_priority: 100, hp_max: 100 }),
    unit({ id: 'escort-b', aggro_priority: 0 }),
  ]
  expect(resolveEncounterLead(units, 'e1')?.id).toBe('the-lead')
})

test('an enemy pack elects no lead, and another fight’s lead is never borrowed', () => {
  const units = [
    unit({ id: 'foe', side: 'enemy', aggro_priority: 100 }),
    unit({ id: 'other-fight-lead', encounter_id: 'e2', aggro_priority: 100 }),
  ]
  expect(resolveEncounterLead(units, 'e1')).toBeNull()
  expect(resolveEncounterLead(units, 'e2')?.id).toBe('other-fight-lead')
})

test('a formation with no marked row has no lead — nothing is invented to stand in', () => {
  expect(resolveEncounterLead([unit({ id: 'a', aggro_priority: null })], 'e1')).toBeNull()
})

// ── ORDNANCE: WHAT THE SHOT IS MADE OF ────────────────────────────────────────────────────────────

test('the round is described by the firing ship’s OWN weapons_json entry the server named', () => {
  const firing = unit({
    id: 'u1',
    weapons_json: [
      { module_type_id: 'autocannon_battery', range: 5, projectile_speed: 60, power: 30 },
      { module_type_id: 'autocannon_battery_mk2', range: 6, projectile_speed: 64, power: 10 },
    ],
  })
  const mk2 = resolveOrdnanceProfile(firing, null, 'autocannon_battery_mk2')!
  expect(mk2.weaponId).toBe('autocannon_battery_mk2')
  expect(mk2.speed).toBe(64)
  expect(mk2.share).toBeCloseTo(0.25, 12) // 10 of 40 — 0331's share, not an invented scale
  expect(mk2.source).toBe('own')

  const main = resolveOrdnanceProfile(firing, null, 'autocannon_battery')!
  expect(main.share).toBeCloseTo(0.75, 12)
  expect(main.speed).toBe(60)
})

test('a lone gun throws the WHOLE volley — share 1, whatever the catalog weight happens to be', () => {
  const a = resolveOrdnanceProfile(unit({ weapons_json: [{ module_type_id: 'g', projectile_speed: 60, power: 3 }] }), null, 'g')!
  const b = resolveOrdnanceProfile(unit({ weapons_json: [{ module_type_id: 'g', projectile_speed: 60, power: 900 }] }), null, 'g')!
  expect(a.share).toBe(1)
  expect(b.share).toBe(1)
})

test('THE FALLBACK: nothing to describe → the ELECTED LEAD’s ordnance, not a hardcoded default', () => {
  const bare = unit({ id: 'bare', aggro_priority: 0, weapons_json: [] })
  const lead = unit({
    id: 'the-lead',
    aggro_priority: 100,
    weapons_json: [{ module_type_id: 'lead_gun', range: 6, projectile_speed: 111, power: 7 }],
  })
  const p = resolveOrdnanceProfile(bare, resolveEncounterLead([bare, lead], 'e1'), null)!
  expect(p.source).toBe('lead')
  expect(p.weaponId).toBe('lead_gun')
  expect(p.speed).toBe(111) // the LEAD's number — a hardcoded default could not produce 111
})

test('a mining rig is not ordnance — an entry with no projectile speed describes no round', () => {
  // 0229's mining_rig_extension carries range 120 and power 8 but no projectile_speed.
  const rig = unit({ weapons_json: [{ module_type_id: 'mining_rig_extension', range: 120, power: 8, projectile_speed: null }] })
  expect(resolveOrdnanceProfile(rig, null, null)).toBeNull()
})

test('neither the ship nor its lead can describe a round → NULL, and none is drawn', () => {
  expect(resolveOrdnanceProfile(unit({ weapons_json: [] }), unit({ weapons_json: [] }), null)).toBeNull()
})

// ── ORDNANCE: IT EXISTS IFF A REAL ATTACK RESOLVED ON THAT TICK ───────────────────────────────────

const endpointsOf = (rows: readonly CombatUnit[]): ReadonlyMap<string, ShotEndpoint> =>
  new Map(
    rows.map((u) => [
      u.id,
      { key: u.id, side: (u.side ?? 'player') as 'player' | 'enemy', x: u.pos_x as number, y: u.pos_y as number },
    ]),
  )

const shotWorld = (events: readonly CombatEvent[], rows: readonly CombatUnit[], nowMs: number, seenAt = T0) => {
  const sightings = observeCombatEvents({}, events, seenAt)
  const latestTick = latestTickByEncounter(events, isSpatialSalvo)
  return resolveOrdnance({ events, latestTick, endpoints: endpointsOf(rows), units: rows, sightings, nowMs })
}

const shooter = unit({ id: 'u1', pos_x: 0, pos_y: 0 })
const target = unit({ id: 'u2', pos_x: 40, pos_y: 0, side: 'enemy', aggro_priority: null })

test('THE PROOF: a round exists exactly when a real salvo resolved on that tick', () => {
  expect(shotWorld([salvo()], [shooter, target], T0 + 10)).toHaveLength(1)
  // No salvo at all → no round. A tick where nothing fired shows nothing.
  expect(shotWorld([hit()], [shooter, target], T0 + 10)).toHaveLength(0)
  expect(shotWorld([], [shooter, target], T0 + 10)).toHaveLength(0)
})

test('an OLDER tick’s salvo draws nothing — only the latest exchange of each fight is in the air', () => {
  const events = [salvo({ id: 9, tick_number: 8 }), salvo({ id: 8, tick_number: 7 })]
  const out = shotWorld(events, [shooter, target], T0 + 10)
  expect(out.map((s) => s.eventId)).toEqual([9])
})

test('two simultaneous fights each get their own latest tick — the younger one is not blanked', () => {
  const rows = [
    shooter,
    target,
    unit({ id: 'v1', encounter_id: 'e2', pos_x: 500, pos_y: 500 }),
    unit({ id: 'v2', encounter_id: 'e2', pos_x: 540, pos_y: 500, side: 'enemy', aggro_priority: null }),
  ]
  const events = [
    salvo({ id: 20, tick_number: 80 }), // e1, an old fight at tick 80
    salvo({ id: 21, encounter_id: 'e2', tick_number: 2, payload_json: { unit_id: 'v1', target_id: 'v2' } }),
  ]
  expect(shotWorld(events, rows, T0 + 10).map((s) => s.eventId)).toEqual([20, 21])
})

test('a shot whose firer or target is NOT on the map draws no lane — never a guessed one', () => {
  expect(shotWorld([salvo({ payload_json: { unit_id: 'ghost', target_id: 'u2' } })], [shooter, target], T0 + 10)).toHaveLength(0)
  expect(shotWorld([salvo({ payload_json: { unit_id: 'u1', target_id: 'ghost' } })], [shooter, target], T0 + 10)).toHaveLength(0)
})

test('the AGGREGATE (dark-path) salvo carries no unit_id and is therefore not a round', () => {
  expect(shotWorld([salvo({ payload_json: { group: 'a' } })], [shooter, target], T0 + 10)).toHaveLength(0)
})

test('a round flies from the firer to the target, monotonically, and is gone once it lands', () => {
  const events = [salvo()]
  let prev = -Infinity
  for (const dt of [1, 50, 100, 150, 200, 250]) {
    const [s] = shotWorld(events, [shooter, target], T0 + dt)
    expect(s.x).toBeGreaterThan(0)
    expect(s.x).toBeLessThan(40) // strictly between the two hulls
    expect(s.x).toBeGreaterThan(prev)
    expect(s.side).toBe('player')
    prev = s.x
  }
  // The flight is bounded, so the round always lands and never lingers over the fight.
  expect(shotWorld(events, [shooter, target], T0 + SHOT_MAX_MS + 1)).toHaveLength(0)
})

test('the flight is the SERVER’s impact_delay_ms — a faster round lands first', () => {
  const slowSeen = observeCombatEvents({}, [salvo({ impact_delay_ms: 200 })], T0)
  const fastSeen = observeCombatEvents({}, [salvo({ impact_delay_ms: 100 })], T0)
  const common = { endpoints: endpointsOf([shooter, target]), units: [shooter, target] }
  const at = (sightings: typeof slowSeen, e: CombatEvent[], nowMs: number) =>
    resolveOrdnance({ ...common, events: e, latestTick: latestTickByEncounter(e, isSpatialSalvo), sightings, nowMs })
  // Sampled while BOTH are still in the air (the fast one's whole flight is 100*4 = 400 ms).
  const t = T0 + 300
  const slow = at(slowSeen, [salvo({ impact_delay_ms: 200 })], t)[0]
  const fast = at(fastSeen, [salvo({ impact_delay_ms: 100 })], t)[0]
  expect(fast.progress).toBeGreaterThan(slow.progress)
  // …and the fast round is down while the slow one is still crossing.
  expect(at(fastSeen, [salvo({ impact_delay_ms: 100 })], T0 + 450)).toHaveLength(0)
  expect(at(slowSeen, [salvo({ impact_delay_ms: 200 })], T0 + 450)).toHaveLength(1)
})

// ── A SERVER 0 IS AN ANSWER, NOT A GAP ────────────────────────────────────────────────────────────
// The tick writes `round(1000 * dist / projectile_speed)::integer` (0234:820, carried to 0299:876),
// and 0316 cut every combat distance by five — so production's delays are 0-120 ms and a
// point-blank shot legitimately writes 0. The client used to guard on `impact_delay_ms > 0` and,
// failing it, re-run the server's own formula over its INTERPOLATED endpoints. This is that branch,
// with the geometry chosen so the two answers cannot be confused: the shooter and the target are 40
// world units apart with a 60 u/s gun, so the client's copy would have computed 1000*40/60 = 667 ms
// → ×4 → clamped to SHOT_MAX_MS (900), while honouring the server's 0 gives the SHOT_MIN_MS floor.

test('THE SERVER’S ZERO IS HONOURED: a point-blank delay lands at the floor, not on the client’s formula', () => {
  const events = [salvo({ impact_delay_ms: 0 })]
  // still on screen just before the playback floor…
  expect(shotWorld(events, [shooter, target], T0 + SHOT_MIN_MS - 20)).toHaveLength(1)
  // …and DOWN immediately after it. Under the old `> 0` guard the client's own
  // 1000*dist/projectile_speed put this round at 900 ms and it would still be crossing here.
  expect(shotWorld(events, [shooter, target], T0 + SHOT_MIN_MS + 1)).toHaveLength(0)
  expect(shotWorld(events, [shooter, target], T0 + 600)).toHaveLength(0)
})

test('a zero-delay round ARRIVES at the floor — the damage number is not held back by client geometry', () => {
  const rows = [shooter, target]
  const events = [salvo({ id: 10, seq: 0, impact_delay_ms: 0 })]
  const arrivals = resolveShotArrivals({
    events,
    latestTick: latestTickByEncounter(events, isSpatialSalvo),
    endpoints: endpointsOf(rows),
    units: rows,
    sightings: observeCombatEvents({}, events, T0),
  })
  expect(arrivals.get('u2#0')).toBe(T0 + SHOT_MIN_MS)
})

test('a row with NO delay at all gets the floor too — never a duration computed from client geometry', () => {
  const events = [salvo({ impact_delay_ms: null })]
  expect(shotWorld(events, [shooter, target], T0 + SHOT_MIN_MS - 20)).toHaveLength(1)
  expect(shotWorld(events, [shooter, target], T0 + SHOT_MIN_MS + 1)).toHaveLength(0)
})

test('THE COPY CANNOT COME BACK: the flight formula lives on the server and nowhere in this module', () => {
  const motion = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'src/features/map/combatMotion.ts'), 'utf8')
  const code = motion
    .split('\n')
    .filter((l) => !l.trimStart().startsWith('*') && !l.trimStart().startsWith('//') && !l.trimStart().startsWith('/*'))
    .join('\n')
  // `1000 * dist / projectile_speed` in any spelling is the server's formula, copied.
  expect(code, 'the flight time must not be re-derived from the gun’s speed').not.toContain('profile.speed')
  expect(code, 'no client-side distance/speed flight math').not.toMatch(/1000\s*\*\s*dist/)
  // …and the guard must never go back to treating a real 0 as a missing value.
  expect(code, 'a 0 delay is a real answer').not.toMatch(/impact_delay_ms\s*>\s*0/)
})

test('a round already in flight is NOT restarted when the same tick arrives on the next poll', () => {
  const events = [salvo()]
  const first = observeCombatEvents({}, events, T0)
  // The 1.5 s poll hands back the identical event rows; the sighting must not move.
  const second = observeCombatEvents(first, events.map((e) => ({ ...e })), T0 + 1500)
  expect(second[1]).toBe(T0)
})

test('a salvo that is gone from the feed is forgotten — the sighting ledger cannot grow forever', () => {
  const first = observeCombatEvents({}, [salvo({ id: 1 }), salvo({ id: 2 })], T0)
  expect(Object.keys(first)).toHaveLength(2)
  expect(Object.keys(observeCombatEvents(first, [salvo({ id: 2 })], T0 + 1500))).toEqual(['2'])
})

test('anyTickArtifactLive is the other half of the loop’s stop condition', () => {
  const seen = observeCombatEvents({}, [salvo()], T0)
  expect(anyTickArtifactLive(seen, T0 + 10)).toBe(true)
  // It outlasts the ROUND on purpose. The loop is what advances `nowMs`, and the damage number the
  // round delivers is drawn until `nowMs` passes its own window — stop at the landing (SHOT_MAX_MS)
  // and the clock freezes with the splat still on screen, which is exactly the corpse that would not
  // let go of its damage. It stops one exchange after the shot, never sooner.
  expect(anyTickArtifactLive(seen, T0 + SHOT_MAX_MS + 1)).toBe(true)
  expect(anyTickArtifactLive(seen, T0 + TICK_READOUT_MS + 1)).toBe(false)
  expect(anyTickArtifactLive({}, T0)).toBe(false)
})

// ── THE STOP CONDITION IS ASKED ON THE CLOCK THAT DREW THE FRAME ───────────────────────────────────
// THE DEFECT THIS STOPS, MEASURED (2026-08-09). The two predicates above are pure and were always
// right; what was wrong was the clock the loop handed them. useCombatMotion's frame loop asked
// `anyTickArtifactLive(sightings, Date.now())` — a clock 5–9 ms AHEAD of `nowMs`, the value the
// frame currently on screen was rendered with, because the effect runs one React commit after it.
// When that lag straddles `seen + TICK_READOUT_MS` the loop tears itself down while the rendered
// frame still carries the splat. And the loop is the ONLY thing that advances `nowMs`, so the clock
// then freezes: the killing blow stays painted on the wreck for as long as the player looks at it.
// That is the owner's original report ("when fleet is destroyed, i want also a damage shown to be
// disappeared as well") surviving inside a one-frame window.
//
// Under parallel workers it reproduced 10 times in 94 runs of the rendered corpse proof. In the
// instrumented batch the signature was exact: 5 frozen runs, all five "live by the RENDER clock,
// already expired by the WALL clock", and 27 passing runs, all twenty-seven expired by both.
// It is a source-shape guard because the fault is not in any value — every pure assertion
// above passes while it happens — it is in WHICH clock the impure shell consults, and that is a
// property of one line of code. A behavioural proof of it can only ever be probabilistic.
test('THE CLOCK CANNOT FREEZE MID-DRAWING: the loop stops on the RENDER clock, never on Date.now()', () => {
  const hook = readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), '..', 'src/features/map/useCombatMotion.ts'),
    'utf8',
  )
    .split('\n')
    .filter((l) => !l.trimStart().startsWith('*') && !l.trimStart().startsWith('//') && !l.trimStart().startsWith('/*'))
    .join('\n')
  // The loop may only stop once a frame has ACTUALLY BEEN RENDERED past the expiry — so both halves
  // of the condition are evaluated at `nowMs`, the clock the frame was drawn with.
  expect(hook, 'the motion half of the stop condition must read the render clock').toContain(
    'anyUnitInMotion(motion, nowMs)',
  )
  expect(hook, 'the readout half of the stop condition must read the render clock').toContain(
    'anyTickArtifactLive(sightings, nowMs)',
  )
  // …and neither may ever be asked on a clock the screen has not caught up to.
  expect(hook, 'the stop condition must never be asked on a fresher clock than the frame').not.toMatch(
    /(anyUnitInMotion|anyTickArtifactLive)\([^)]*Date\.now\(\)/,
  )
})

// ── THE EXCHANGE'S OWN WINDOW ─────────────────────────────────────────────────────
// The owner: "when fleet is destroyed, i want also a damage shown to be disappeared as well." A
// tick's artifacts had a start and no end; this ledger is what gives them an age.
test('the ledger tracks every artifact of an exchange, not just the salvos', () => {
  const seen = observeCombatEvents(
    {},
    [
      salvo({ id: 1 }),
      salvo({ id: 2, event_type: 'hull_damage', payload_json: { unit_id: 'a', damage: 4 } }),
      salvo({ id: 3, event_type: 'unit_destroyed', payload_json: { unit_id: 'a', count: 1 } }),
    ],
    T0,
  )
  expect(Object.keys(seen).sort()).toEqual(['1', '2', '3'])
  // …and the AGGREGATE (dark-path) rows, which name a `group` and no unit, are drawn nowhere and
  // therefore tracked nowhere — the same predicate the layer draws by.
  expect(observeCombatEvents({}, [salvo({ id: 9, payload_json: { group: 'alpha', damage: 3 } })], T0)).toEqual({})
  expect(isTickArtifact(salvo({ id: 9, payload_json: { group: 'alpha' } }))).toBe(false)
  expect(isTickArtifact(salvo({ id: 1, event_type: 'wave_spawned', payload_json: { unit_id: 'a' } }))).toBe(false)
  expect(isTickArtifact(salvo({ id: 1, event_type: 'hull_damage', payload_json: { unit_id: 'a' } }))).toBe(true)
})

test('an artifact is live for exactly one exchange, and an UNSEEN one is never hidden', () => {
  const seen = observeCombatEvents({}, [salvo({ id: 7 })], T0)
  expect(tickArtifactLive(seen, 7, T0)).toBe(true)
  expect(tickArtifactLive(seen, 7, T0 + TICK_READOUT_MS - 1)).toBe(true)
  expect(tickArtifactLive(seen, 7, T0 + TICK_READOUT_MS)).toBe(false)
  // No ledger at all, or an id the ledger never saw → LIVE. A caller that keeps no sightings gets
  // exactly the pre-expiry behaviour, and a real event is never dropped because the client blinked.
  expect(tickArtifactLive(undefined, 7, T0 + 10 * TICK_READOUT_MS)).toBe(true)
  expect(tickArtifactLive(seen, 8, T0 + 10 * TICK_READOUT_MS)).toBe(true)
})

// The window is DERIVED, never a second number: it is this file's own bound on one plausible server
// tick, so a cadence change moves the readout with it.
test('the exchange window IS the one-plausible-tick bound', () => {
  expect(TICK_READOUT_MS).toBe(STEP_MAX_MS)
})

// ── ORDNANCE: THE FALLBACK IS VISIBLE END TO END ──────────────────────────────────────────────────

test('END TO END: a firing ship with nothing fitted draws the LEAD’s round, and says so', () => {
  const bare = unit({ id: 'u1', pos_x: 0, pos_y: 0, aggro_priority: 0, weapons_json: [] })
  const lead = unit({
    id: 'lead',
    pos_x: 5,
    pos_y: 0,
    aggro_priority: 100,
    weapons_json: [{ module_type_id: 'lead_gun', range: 6, projectile_speed: 90, power: 12 }],
  })
  const rows = [bare, lead, target]
  const [s] = shotWorld([salvo({ projectile_type: 'nothing_this_ship_has' })], rows, T0 + 10)
  expect(s.profileSource).toBe('lead')
  expect(s.share).toBe(1)
})

test('END TO END: with no lead either, the shot is simply not drawn', () => {
  const bare = unit({ id: 'u1', pos_x: 0, pos_y: 0, aggro_priority: null, weapons_json: [] })
  expect(shotWorld([salvo()], [bare, target], T0 + 10)).toHaveLength(0)
})

// ── THE DAMAGE NUMBER ARRIVES WITH ITS OWN ROUND ──────────────────────────────────────────────────

test('the k-th hit on a hull is paired with the k-th round aimed at it, in the SERVER’s order', () => {
  const rows = [shooter, unit({ id: 'u3', pos_x: 0, pos_y: 40 }), target]
  const events = [
    salvo({ id: 10, seq: 0, payload_json: { unit_id: 'u1', target_id: 'u2' }, impact_delay_ms: 100 }),
    salvo({ id: 12, seq: 2, payload_json: { unit_id: 'u3', target_id: 'u2' }, impact_delay_ms: 200 }),
  ]
  const sightings = observeCombatEvents({}, events, T0)
  const arrivals = resolveShotArrivals({
    events,
    latestTick: latestTickByEncounter(events, isSpatialSalvo),
    endpoints: endpointsOf(rows),
    units: rows,
    sightings,
  })
  const first = arrivals.get('u2#0')!
  const second = arrivals.get('u2#1')!
  expect(first).toBeGreaterThanOrEqual(T0 + SHOT_MIN_MS)
  expect(second).toBeGreaterThan(first) // the slower round lands later — the numbers do not tie
})

test('a damage row with NO matching round is left unpaired, so a real hit is never hidden', () => {
  const rows = [shooter, target]
  const events = [hit({ id: 5, seq: 0 })] // an aggregate-arm hit: no salvo at all
  const arrivals = resolveShotArrivals({
    events,
    latestTick: latestTickByEncounter(events, isSpatialSalvo),
    endpoints: endpointsOf(rows),
    units: rows,
    sightings: observeCombatEvents({}, events, T0),
  })
  expect(arrivals.size).toBe(0)
})

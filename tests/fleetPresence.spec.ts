import { test, expect } from '@playwright/test'
import type { ReactElement } from 'react'
import { ICON_PATHS } from '../src/components/ui/icons'
import { MARKER_BELOW_LABEL_OFFSET } from '../src/features/map/markerStyle'
import { fleetLayer, TeamMovingMarkers, FleetPointBadge } from '../src/features/map/teamMarkers'
import {
  FLEET_PRESENCE_STATES,
  resolveFleetPresence,
  type FleetPresenceState,
  type PositionRow,
  type PresenceLocation,
} from '../src/features/map/fleetPresence'
import { shipVisual } from '../src/features/map/shipVisual'
import { interpolateMovementPoint } from '../src/features/map/movementInterpolation'
import type { FleetMovement } from '../src/features/fleets/fleetTypes'
import type { GroupRow, ShipGroupMapEntry } from '../src/features/command/teamRoster'
// type-only import — erased at compile, so the spec never loads teamApi's supabase client.
import type { UnifiedGroupFleetLite } from '../src/features/command/teamApi'
import type { FleetEncounterLite } from '../src/features/combat/encounterAnchor'
import type { CombatUnit } from '../src/features/combat/combatTypes'

// ██ WHERE IS MY FLEET ██ — pure specs for the ONE presence authority (map/fleetPresence) and the
// element-descriptor layer that draws it (map/teamMarkers), through the SAME functions GalaxyMap
// calls. No hooks run, no DB, no fabricated backend.
//
// THE PROPERTY THIS SUITE EXISTS TO PIN, and the reason it is TABLE-DRIVEN over
// FLEET_PRESENCE_STATES: **a fleet in EVERY state produces exactly ONE map marker.** The defect it
// replaced was four resolvers each deciding EXISTENCE for itself, so a fleet matching none of them was
// drawn nowhere at all. A sixth state added without a marker fails the table below — which is the
// whole point: the next state cannot quietly reopen the hole.
//
// (This file supersedes tests/teamMarkers.spec.ts, deleted with the four resolvers it proved. The
// coverage that was about the SHARED interpolation and the badge presentation is carried over here
// rather than dropped.)

const DEP = '2026-01-01T00:00:00Z'
const ARR = '2026-01-01T00:10:00Z'
const depMs = Date.parse(DEP)
const arrMs = Date.parse(ARR)
const midMs = (depMs + arrMs) / 2
const norm = (p: { x: number; y: number }) => p // identity stub; positions pass through unchanged

const mv = (o: Partial<FleetMovement> = {}): FleetMovement =>
  ({
    id: 'm1',
    fleet_id: 'f1',
    origin_type: 'base',
    origin_x: 0,
    origin_y: 0,
    target_type: 'location',
    target_location_id: 'loc-A',
    target_base_id: null,
    target_x: 100,
    target_y: 200,
    mission_type: 'rally',
    status: 'moving',
    depart_at: DEP,
    arrive_at: ARR,
    travel_seconds: 600,
    travel_distance: 100,
    group_id: null,
    ...o,
  }) as FleetMovement

// ── The world ──────────────────────────────────────────────────────────────────────────────────────
// Two groups, deliberately named "Alpha" and "Fleet 2" so the ONE naming rule (fleetLabel) is
// exercised both ways: a name that already says "Fleet" must not come back as "Fleet Fleet 2".
const G1: GroupRow = { group_id: 'g1', group_index: 1, name: 'Alpha' }
const G2: GroupRow = { group_id: 'g2', group_index: 2, name: 'Fleet 2' }
const groups: GroupRow[] = [G1, G2]

const HAVEN: PresenceLocation = { id: 'loc-haven', name: 'Haven', x: 10, y: 20, territory_radius: 40, activity_type: 'none' }
const SLAG: PresenceLocation = { id: 'loc-slag', name: 'Slagworks', x: 300, y: 400, territory_radius: null, activity_type: 'none' }
const REAVER: PresenceLocation = { id: 'loc-reaver', name: 'Reaver', x: -500, y: 600, territory_radius: null, activity_type: 'hunt_pirates' }
const locations: PresenceLocation[] = [HAVEN, SLAG, REAVER]

const member = (o: Partial<ShipGroupMapEntry> = {}): ShipGroupMapEntry => ({
  group_id: 'g1',
  captain_slots: 2,
  is_command_ship: false,
  ...o,
})
/** Membership map for a group: `crew('g1', 4)` → s1..s4, all in g1. */
const crew = (groupId: string, n: number, offset = 0): Record<string, ShipGroupMapEntry> => {
  const out: Record<string, ShipGroupMapEntry> = {}
  for (let i = 1; i <= n; i++) out[`s${offset + i}`] = member({ group_id: groupId })
  return out
}

// The row shape is taken FROM the module under test (PositionRow) rather than restated here, so a
// widening like `class` cannot drift between the fixture and its reader. `class` IS `hull_type_id`,
// and all 77 live ships are `starter_frigate` — so that is what a fixture inherits unless it is
// deliberately about another hull.
type Pos = PositionRow
const pos = (o: Partial<Pos> & Pick<Pos, 'main_ship_id' | 'place'>): Pos => ({
  class: 'starter_frigate',
  location_id: null,
  segment: null,
  space_x: null,
  space_y: null,
  ...o,
})
const dockedAt = (shipId: string, loc: Pick<PresenceLocation, 'id'>): Pos =>
  pos({ main_ship_id: shipId, place: 'docked', location_id: loc.id })
const hidden = (shipId: string): Pos => pos({ main_ship_id: shipId, place: 'hidden' })
const inTransit = (shipId: string): Pos =>
  pos({
    main_ship_id: shipId,
    place: 'transit',
    segment: { origin_x: 0, origin_y: 0, target_x: 100, target_y: 200, target_kind: 'location', depart_at: DEP, arrive_at: ARR },
  })
const parked = (shipId: string, x: number, y: number): Pos =>
  pos({ main_ship_id: shipId, place: 'in_space', space_x: x, space_y: y })

const fleetRow = (o: Partial<UnifiedGroupFleetLite> = {}): Pick<UnifiedGroupFleetLite, 'id' | 'group_id'> => ({
  id: 'fleet-g1',
  group_id: 'g1',
  ...o,
})

// ── The real production fight (the numbers behind two shipped bugs) ────────────────────────────────
// Measured on the owner's own ambush: three enemy units stacked on ONE point 5.0 from the engagement
// anchor, four player ships scattered 20.7-28.1 from it. Their centroid (-26.15, 113.475) has NO SHIP
// ON IT. The badge must land on Sparrow V (-11.4, 99.0) — the hull nearest the enemy, the point of
// attack. tests/fleetFightPosition.spec.ts owns that RULE; this suite owns the WIRING to it.
const PARK = { x: -31.968, y: 96.627 }
const ENEMY = { x: -27.0, y: 97.2 }
const ATTACK = { x: -11.4, y: 99.0 }
const CENTROID = { x: -26.15, y: 113.475 }

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
const formation = (): CombatUnit[] => [
  unit({ id: 'p1-sparrow', pos_x: ATTACK.x, pos_y: ATTACK.y }),
  unit({ id: 'p2-kite', pos_x: -17.5, pos_y: 116.6 }),
  unit({ id: 'p3-far', pos_x: -47.1, pos_y: 113.7 }),
  unit({ id: 'p4-rear', pos_x: -28.6, pos_y: 124.6 }),
]
const enemies = (): CombatUnit[] =>
  ['e-a', 'e-b', 'e-c'].map((id) => unit({ id, side: 'enemy', pos_x: ENEMY.x, pos_y: ENEMY.y }))
const enc = (o: Partial<FleetEncounterLite> = {}): FleetEncounterLite => ({
  id: 'e1',
  fleet_id: 'fleet-g1',
  status: 'active',
  ...o,
})

type World = Parameters<typeof resolveFleetPresence>[0]

/** One group ('g1', two ships) in each state, so the table can walk the whole closed set. */
function worldFor(state: FleetPresenceState): World {
  const base = {
    groups: [G1],
    membership: crew('g1', 2),
    locations,
    fleets: [fleetRow()],
    nowMs: midMs,
  }
  switch (state) {
    case 'in-combat':
      return {
        ...base,
        positions: [parked('s1', PARK.x, PARK.y), parked('s2', PARK.x, PARK.y)],
        encounters: [enc()],
        units: [...formation(), ...enemies()],
      }
    case 'moving':
      return { ...base, positions: [inTransit('s1'), inTransit('s2')] }
    case 'in-space':
      return { ...base, positions: [parked('s1', PARK.x, PARK.y), parked('s2', PARK.x, PARK.y)] }
    case 'docked':
      return { ...base, positions: [dockedAt('s1', HAVEN), dockedAt('s2', HAVEN)] }
    case 'unplaced':
      return { ...base, positions: [hidden('s1'), hidden('s2')] }
  }
}

/**
 * HOW MANY MARKERS THIS FLEET HAS ON THE MAP — the whole suite's unit of measure.
 *
 * A marker is ANY of the three things the layer can produce, because all three are what the player
 * sees and all three carry `fleet-marker-<groupId>`:
 *   · a world badge in the camera tree (docked / in-space / in-combat)
 *   · a badge drawn by the moving host, which owns the 1s clock (in transit)
 *   · a rail entry for a fleet the world cannot place (unplaced)
 * Counting them TOGETHER is what makes "a fleet is always on the map, exactly once" one assertion
 * instead of five special cases — and it is what would have caught the original defect, where the
 * total was zero.
 */
function markersFor(layer: ReturnType<typeof fleetLayer>, groupId: string): number {
  const world = layer.elements.filter((e) => (e.props as { groupId?: string }).groupId === groupId).length
  const rail = layer.unplaced.filter((p) => p.groupId === groupId).length
  const host = layer.elements.find((e) => e.type === TeamMovingMarkers)
  const hostProps = host?.props as { active: boolean; resolve: (n: number) => { groupId: string; state: string; at: unknown }[] } | undefined
  const moving = hostProps?.active
    ? hostProps.resolve(midMs).filter((p) => p.groupId === groupId && p.state === 'moving' && p.at !== null).length
    : 0
  return world + rail + moving
}

const layerFor = (w: World) =>
  fleetLayer({
    groups: w.groups as GroupRow[],
    membership: w.membership,
    positions: w.positions,
    fleets: w.fleets,
    locations,
    norm,
    k: 1,
    nowMs: w.nowMs,
    encounters: w.encounters,
    units: w.units,
  })

// ── interpolateMovementPoint — the ONE shared clamp-lerp the presence fold composes ────────────────
test('interpolateMovementPoint: midpoint at t=0.5', () => {
  expect(interpolateMovementPoint(mv(), midMs)).toEqual({ x: 50, y: 100 })
})

test('interpolateMovementPoint: clamps before departure (origin) and after arrival (target)', () => {
  expect(interpolateMovementPoint(mv(), depMs - 60_000)).toEqual({ x: 0, y: 0 })
  expect(interpolateMovementPoint(mv(), arrMs + 60_000)).toEqual({ x: 100, y: 200 })
})

test('interpolateMovementPoint: null on invalid/inverted times or non-finite coordinates', () => {
  expect(interpolateMovementPoint(mv({ arrive_at: DEP }), midMs)).toBeNull() // arr <= dep
  expect(interpolateMovementPoint(mv({ depart_at: 'not-a-date' }), midMs)).toBeNull()
  expect(interpolateMovementPoint(mv({ target_x: Number.NaN }), midMs)).toBeNull()
})

// ══ THE TABLE — every state, exactly one presence and exactly one marker ═══════════════════════════

test('THE STATE SET IS CLOSED, and every member of it is actually reachable', () => {
  expect([...FLEET_PRESENCE_STATES].slice().sort()).toEqual(
    ['docked', 'in-combat', 'in-space', 'moving', 'unplaced'].sort(),
  )
  // A table row that cannot be built is a state that would silently never be exercised.
  for (const state of FLEET_PRESENCE_STATES) {
    expect(resolveFleetPresence(worldFor(state)).map((p) => p.state)).toEqual([state])
  }
})

for (const state of FLEET_PRESENCE_STATES) {
  test(`state "${state}": EXACTLY ONE presence, and \`at\` is null only when unplaceable`, () => {
    const out = resolveFleetPresence(worldFor(state))
    expect(out).toHaveLength(1)
    expect(out[0].groupId).toBe('g1')
    expect(out[0].state).toBe(state)
    expect(out[0].memberCount).toBe(2)
    // The invariant that stops a badge ever standing on a coordinate nobody committed.
    expect(out[0].at === null).toBe(state === 'unplaced')
    expect(out[0].placedCount === 0).toBe(state === 'unplaced')
    if (out[0].at) {
      expect(Number.isFinite(out[0].at.x)).toBe(true)
      expect(Number.isFinite(out[0].at.y)).toBe(true)
    }
  })

  test(`state "${state}": EXACTLY ONE map marker`, () => {
    const layer = layerFor(worldFor(state))
    expect(markersFor(layer, 'g1')).toBe(1)
    // The moving badge is drawn inside TeamMovingMarkers (it carries the 1s clock), so the layer's own
    // child for it is that component — armed exactly when something is moving, and never otherwise.
    const host = layer.elements.filter((e) => e.type === TeamMovingMarkers)
    expect(host).toHaveLength(1)
    expect((host[0].props as { active: boolean }).active).toBe(state === 'moving')
  })
}

test('the moving badge re-reads the ONE authority on its clock — it does not interpolate again', () => {
  const layer = layerFor(worldFor('moving'))
  const host = layer.elements.find((e) => e.type === TeamMovingMarkers)
  const resolve = (host!.props as { resolve: (n: number) => { at: { x: number; y: number } | null }[] }).resolve
  expect(resolve(midMs)[0].at).toEqual({ x: 50, y: 100 })
  expect(resolve(depMs)[0].at).toEqual({ x: 0, y: 0 })
  expect(resolve(arrMs)[0].at).toEqual({ x: 100, y: 200 })
})

// ══ THE REGRESSION THAT STARTED THIS ═══════════════════════════════════════════════════════════════

test('THE OWNER’S BUG: a fleet with only SOME ships placed is still on the map, counted honestly', () => {
  // Production, 2026-08-04: Fleet 1 has four ships. ONE is docked at Haven; the other three carry the
  // abolished `legacy_home` state, so the server projects them 'hidden'. The old dock fold demanded a
  // COMPLETE n/n rollup, answered null, and the whole fleet vanished from the map.
  const out = resolveFleetPresence({
    groups: [G1],
    membership: crew('g1', 4),
    positions: [dockedAt('s1', HAVEN), hidden('s2'), hidden('s3'), hidden('s4')],
    locations,
    nowMs: midMs,
  })
  expect(out).toHaveLength(1)
  expect(out[0].state).toBe('docked')
  expect(out[0].at).toEqual({ x: HAVEN.x, y: HAVEN.y })
  expect(out[0].placedCount).toBe(1)
  expect(out[0].memberCount).toBe(4)
  expect(out[0].label).toBe('Fleet Alpha 1/4')
})

test('a fleet split across two ports gets ONE badge, at the port holding the most of it', () => {
  const out = resolveFleetPresence({
    groups: [G1],
    membership: crew('g1', 4),
    positions: [dockedAt('s1', HAVEN), dockedAt('s2', SLAG), dockedAt('s3', SLAG), dockedAt('s4', SLAG)],
    locations,
    nowMs: midMs,
  })
  // ONE fleet, ONE marker: never two labels for one fleet, and never a port cluttered with a badge for
  // a fleet that is mostly somewhere else.
  expect(out).toHaveLength(1)
  expect(out[0].locationId).toBe(SLAG.id)
  expect(out[0].label).toBe('Fleet Alpha 4/4')
})

test('an even split breaks on the LOWEST location id — deterministic, never a coin flip', () => {
  const half = (order: Pos[]) =>
    resolveFleetPresence({ groups: [G1], membership: crew('g1', 2), positions: order, locations, nowMs: midMs })[0]
  const a = half([dockedAt('s1', HAVEN), dockedAt('s2', SLAG)])
  const b = half([dockedAt('s1', SLAG), dockedAt('s2', HAVEN)])
  expect(a.locationId).toBe(b.locationId)
  expect(a.locationId).toBe(HAVEN.id) // 'loc-haven' < 'loc-slag'
})

test('N fleets at ONE port each keep their own badge, stacked — never one label under another', () => {
  const layer = fleetLayer({
    groups,
    membership: { ...crew('g1', 1), ...crew('g2', 1, 1) },
    positions: [dockedAt('s1', HAVEN), dockedAt('s2', HAVEN)],
    locations,
    norm,
    k: 1,
    nowMs: midMs,
  })
  const docks = layer.elements.filter((e) => (e.props as { state?: string }).state === 'docked')
  expect(docks).toHaveLength(2)
  expect(docks.map((e) => (e.props as { stack: number }).stack)).toEqual([0, 1])
  // …and the naming rule is composed, not copied: a group already NAMED "Fleet 2" never doubles up.
  expect(docks.map((e) => (e.props as { label: string }).label)).toEqual(['Fleet Alpha 1/1', 'Fleet 2 1/1'])
})

// ══ PRECEDENCE — the strongest thing the fleet is doing decides where it is drawn ══════════════════

test('precedence: combat > moving > in-space > docked', () => {
  const at = (positions: Pos[], extra: Partial<World> = {}) =>
    resolveFleetPresence({
      groups: [G1], membership: crew('g1', 3), positions, locations, fleets: [fleetRow()], nowMs: midMs, ...extra,
    })[0]
  expect(at([dockedAt('s1', HAVEN), parked('s2', PARK.x, PARK.y), inTransit('s3')]).state).toBe('moving')
  expect(at([dockedAt('s1', HAVEN), parked('s2', PARK.x, PARK.y), hidden('s3')]).state).toBe('in-space')
  expect(at([dockedAt('s1', HAVEN), hidden('s2'), hidden('s3')]).state).toBe('docked')
  expect(
    at([dockedAt('s1', HAVEN), parked('s2', PARK.x, PARK.y), inTransit('s3')], {
      encounters: [enc()],
      units: [...formation(), ...enemies()],
    }).state,
  ).toBe('in-combat')
})

// ══ THE FIGHT — composed from fleetFightPosition, never re-derived here ════════════════════════════

test('a fighting fleet stands on ONE OF ITS OWN SHIPS, at the point of attack', () => {
  const [p] = resolveFleetPresence({
    groups: [G1],
    membership: crew('g1', 4),
    positions: [1, 2, 3, 4].map((i) => parked(`s${i}`, PARK.x, PARK.y)),
    locations,
    fleets: [fleetRow()],
    encounters: [enc()],
    units: [...formation(), ...enemies()],
    nowMs: midMs,
  })
  expect(p.state).toBe('in-combat')
  // THE FIRST SHIPPED BUG: the badge sat on the fleet's parked point, 20-28 units from its own ships.
  expect(p.at).not.toEqual(PARK)
  // THE SECOND: then on their CENTROID — a point where no ship of theirs is standing.
  expect(p.at).not.toEqual(CENTROID)
  expect(p.at).toEqual(ATTACK)
  // The enemy stack is the distance TARGET and never the answer.
  expect(p.at).not.toEqual(ENEMY)
  // The drawn point is a MEMBER of the fleet's own hulls — membership, not proximity.
  expect(formation().map((u) => `${u.pos_x},${u.pos_y}`)).toContain(`${p.at!.x},${p.at!.y}`)
})

test('a fleet fighting with NO positioned ship keeps its resting point and still says it is fighting', () => {
  const [p] = resolveFleetPresence({
    groups: [G1],
    membership: crew('g1', 1),
    positions: [parked('s1', PARK.x, PARK.y)],
    locations,
    fleets: [fleetRow()],
    encounters: [enc()],
    units: [unit({ pos_x: null, pos_y: null })],
    nowMs: midMs,
  })
  expect(p.state).toBe('in-combat')
  expect(p.at).toEqual(PARK)
  expect(p.label).toBe('Fleet Alpha 1/1 · in combat')
})

test('a fleet fighting at a SITE names the site; only ITS OWN encounter can move it', () => {
  const world: World = {
    groups: [G1],
    membership: crew('g1', 1),
    positions: [dockedAt('s1', REAVER)],
    locations,
    fleets: [fleetRow()],
    nowMs: midMs,
  }
  const mine = resolveFleetPresence({ ...world, encounters: [enc()], units: [] })[0]
  expect(mine.state).toBe('in-combat')
  expect(mine.label).toBe('Fleet Alpha 1/1 · in combat at Reaver')
  expect(mine.locationId).toBe(REAVER.id)
  // Another fleet's fight is not ours: no encounter matches, so this reads as an ordinary dock.
  const theirs = resolveFleetPresence({ ...world, encounters: [enc({ fleet_id: 'someone-else' })], units: [] })[0]
  expect(theirs.state).toBe('docked')
  // Two live fights for one fleet is a broken server invariant — no anchor, never a coin flip.
  const ambiguous = resolveFleetPresence({ ...world, encounters: [enc(), enc({ id: 'e2' })], units: [] })[0]
  expect(ambiguous.state).toBe('docked')
})

test('a parked fleet inside a territory says whose orbit it is in — from the point it is DRAWN at', () => {
  const inOrbit = resolveFleetPresence({
    groups: [G1], membership: crew('g1', 1), positions: [parked('s1', HAVEN.x + 5, HAVEN.y)], locations, nowMs: midMs,
  })[0]
  expect(inOrbit.label).toBe('Fleet Alpha 1/1 · in orbit of Haven')
  const deepSpace = resolveFleetPresence({
    groups: [G1], membership: crew('g1', 1), positions: [parked('s1', 9000, 9000)], locations, nowMs: midMs,
  })[0]
  expect(deepSpace.label).toBe('Fleet Alpha 1/1') // never a guessed place
})

// ══ FAIL CLOSED — no invented positions, no leaked ids ═════════════════════════════════════════════

test('a dock at a site OUTSIDE the visible world read places nothing (no badge, no id leak)', () => {
  const [p] = resolveFleetPresence({
    groups: [G1], membership: crew('g1', 1), positions: [dockedAt('s1', { id: 'loc-secret' })], locations, nowMs: midMs,
  })
  expect(p.state).toBe('unplaced')
  expect(p.at).toBeNull()
  expect(p.locationId).toBeNull()
  // 0 of 1 placed: the ship exists, but nothing the map can see says where it is.
  expect(p.label).toBe('Fleet Alpha 0/1 · location unknown')
})

test('unusable coordinates place nothing rather than pushing NaN into an SVG transform', () => {
  const bad = (positions: Pos[], locs: PresenceLocation[] = locations) =>
    resolveFleetPresence({ groups: [G1], membership: crew('g1', 1), positions, locations: locs, nowMs: midMs })[0]
  expect(bad([parked('s1', Number.NaN, 1)]).at).toBeNull()
  expect(bad([pos({ main_ship_id: 's1', place: 'in_space' })]).at).toBeNull() // in_space with no coordinates
  expect(bad([pos({ main_ship_id: 's1', place: 'transit' })]).at).toBeNull() // transit with no segment
  expect(bad([dockedAt('s1', HAVEN)], [{ ...HAVEN, x: Number.NaN }]).at).toBeNull()
})

test('a "berthed" ship is placed exactly like a docked one — a berth is a port', () => {
  const [p] = resolveFleetPresence({
    groups: [G1],
    membership: crew('g1', 1),
    positions: [pos({ main_ship_id: 's1', place: 'berthed', location_id: SLAG.id })],
    locations,
    nowMs: midMs,
  })
  expect(p.state).toBe('docked')
  expect(p.at).toEqual({ x: SLAG.x, y: SLAG.y })
})

test('a group with NO members is unplaced (0/0) — reported, never silently dropped', () => {
  const [p] = resolveFleetPresence({ groups: [G1], membership: {}, positions: [], locations, nowMs: midMs })
  expect(p.state).toBe('unplaced')
  expect(p.label).toBe('Fleet Alpha 0/0 · location unknown')
})

test('a foreign ship never joins one of MY fleets; zero groups renders nothing at all', () => {
  const [p] = resolveFleetPresence({
    groups: [G1],
    membership: { ...crew('g1', 1), sX: member({ group_id: 'someone-elses-group' }) },
    positions: [dockedAt('s1', HAVEN), dockedAt('sX', SLAG)],
    locations,
    nowMs: midMs,
  })
  expect(p.placedCount).toBe(1)
  expect(p.locationId).toBe(HAVEN.id)
  expect(resolveFleetPresence({ groups: [], membership: crew('g1', 1), positions: [], locations, nowMs: midMs })).toEqual([])
  expect(fleetLayer({ groups: [], membership: {}, positions: [], locations, norm, k: 1, nowMs: midMs })).toEqual({
    elements: [],
    unplaced: [],
  })
})

test('output order is deterministic — the same rows always answer the same list', () => {
  const build = (gs: GroupRow[]) =>
    resolveFleetPresence({
      groups: gs,
      membership: { ...crew('g1', 1), ...crew('g2', 1, 1) },
      positions: [dockedAt('s1', HAVEN), dockedAt('s2', SLAG)],
      locations,
      nowMs: midMs,
    })
  expect(build([G1, G2])).toEqual(build([G2, G1]))
  expect(build([G1, G2]).map((p) => p.groupId)).toEqual(['g1', 'g2'])
})

// ══ PRESENTATION — the state picks the DECORATION; it never picks the ship ══════════════
//
// REPOINTED, and this is the whole point of the slice. There used to be THREE badge components here
// (FleetPointBadge / TeamDockBadge / TeamCombatBadge) and the test below asserted only that all three
// carried one testid — the strongest property available while three components existed. Two of them
// are DELETED. There is ONE badge, it draws the ship from the ONE authority, and the state chooses
// only the ring, the label side and the lane. So the property is now the owner's own words: "the
// fleet shape changes when in a combat, and outside combat. I want it to be same."

const VISUAL = shipVisual({ typeId: 'starter_frigate', side: 'player', kind: 'fleet', mass: 2000 })
const badgeIn = (state: FleetPresenceState, o: Record<string, unknown> = {}) =>
  FleetPointBadge({ groupId: 'g1', label: 'x', x: 1, y: 2, k: 1, state, visual: VISUAL, ...o })
const kidsOf = (el: ReactElement): (ReactElement | null)[] =>
  (el.props as { children: (ReactElement | null)[] }).children
const hullOf = (el: ReactElement) =>
  kidsOf(el).find((c) => c && (c.props as Record<string, unknown>)['data-ship-form'])

test('THE PROOF — the SHIP is identical in every state; only the decoration differs', () => {
  const shipOf = (state: FleetPresenceState) => {
    const { d, fill, fillOpacity } = hullOf(badgeIn(state))!.props as {
      d: string
      fill: string
      fillOpacity: number
    }
    // the SHAPE, the tone and the dimming — not the transform, which carries the state's placement
    return { d, fill, fillOpacity }
  }
  const inSpace = shipOf('in-space')
  for (const state of ['moving', 'docked', 'in-combat'] as const) {
    expect(shipOf(state), `${state} must draw the SAME ship as a resting fleet`).toEqual(inSpace)
  }
  // …and it is the design system's own ship silhouette, not a shape invented at a draw site.
  expect(inSpace.d).toBe(ICON_PATHS.ship.join(' '))
})

test('a fleet whose fight is POSITIONED draws no second hull — the combat layer already has it', () => {
  // Both layers stand a fighting fleet on the same point (map/fleetFightPosition), so a hull from
  // each is one fleet drawn twice. `fightGlyph` is where that is decided, once, on the presence.
  const badge = badgeIn('in-combat', { fightGlyph: true })
  expect(hullOf(badge)).toBeUndefined()
  // …but the ring and the label still say a fight is happening.
  expect(JSON.stringify(badge.props)).toContain('--color-danger')
})

test('a DOCKED badge clears the port marker instead of burying it', () => {
  // Live on the owner's map 2026-08-04: "Fleet 2 1/1" rendered across the Slagworks diamond. The
  // clearance is markerStyle's (46 on-screen px, against the biggest marker's 27.6px halo) and it
  // now has to hold for the whole badge — the ship as well as the text.
  const badge = badgeIn('docked')
  const half = VISUAL.sizePx // k = 1 and pxScale defaults to 1, so viewBox units == on-screen px
  const laneTop = 2 + MARKER_BELOW_LABEL_OFFSET // y=2, plus the clearance markerStyle owns
  // the glyph's CENTRE is one half-size below the clearance line, i.e. its top sits exactly on it
  expect((hullOf(badge)!.props as { transform: string }).transform).toContain(
    `translate(1 ${laneTop + half})`,
  )
  const label = kidsOf(badge).find((c) => c && c.type === 'text')!
  expect((label.props as { y: number }).y).toBeGreaterThan(laneTop + 2 * half)
})

test('every state carries the SAME fleet-marker testid, so "one marker" is one query', () => {
  const ids = FLEET_PRESENCE_STATES.map(
    (state) => (badgeIn(state).props as { 'data-testid': string })['data-testid'],
  )
  expect(ids).toEqual(FLEET_PRESENCE_STATES.map(() => 'fleet-marker-g1'))
})

test('badges are pointer-transparent — a fleet label never steals the map’s tap target', () => {
  for (const state of FLEET_PRESENCE_STATES) {
    expect((badgeIn(state).props as { style: { pointerEvents: string } }).style.pointerEvents).toBe('none')
  }
})

test('a fight badge is danger-tinted and a resting one is not — the state is visible, not just written', () => {
  expect(JSON.stringify(badgeIn('in-combat').props)).toContain('--color-danger')
  expect(JSON.stringify(badgeIn('in-space').props)).toContain('--color-accent')
})

test('co-fighting fleets at ONE site stack their labels — two fights, two readable badges', () => {
  const layer = fleetLayer({
    groups,
    membership: { ...crew('g1', 1), ...crew('g2', 1, 1) },
    positions: [dockedAt('s1', REAVER), dockedAt('s2', REAVER)],
    // Each group's OWN fleet row, each with its OWN live encounter — one fight is not the other's.
    fleets: [fleetRow(), fleetRow({ id: 'fleet-g2', group_id: 'g2' })],
    encounters: [enc(), enc({ id: 'e2', fleet_id: 'fleet-g2' })],
    units: [],
    locations,
    norm,
    k: 1,
    nowMs: midMs,
  })
  const fights = layer.elements.filter((e) => (e.props as { state?: string }).state === 'in-combat')
  expect(fights).toHaveLength(2)
  expect(fights.map((e) => (e.props as { stack: number }).stack)).toEqual([0, 1])
})

test('every badge is placed THROUGH the map projection — the layer never draws in world units', () => {
  // `norm` is the map's ONE world→viewBox transform. A badge that skipped it would sit on the right
  // spot in the wrong space, which reads as "somewhere near, but not where the ship is".
  const project = (p: { x: number; y: number }) => ({ x: p.x * 2 + 7, y: p.y * 3 - 1 })
  const layer = fleetLayer({
    groups: [G1],
    membership: crew('g1', 1),
    positions: [dockedAt('s1', SLAG)],
    locations,
    norm: project,
    k: 1,
    nowMs: midMs,
  })
  const badge = layer.elements.find((e) => (e.props as { state?: string }).state === 'docked')!.props as {
    x: number
    y: number
  }
  expect({ x: badge.x, y: badge.y }).toEqual(project({ x: SLAG.x, y: SLAG.y }))
})

test('the layer keeps unplaced fleets OUT of the world tree and hands them over separately', () => {
  const layer = fleetLayer({
    groups,
    membership: { ...crew('g1', 1), ...crew('g2', 1, 1) },
    positions: [dockedAt('s1', HAVEN), hidden('s2')],
    locations,
    norm,
    k: 1,
    nowMs: midMs,
  })
  expect(layer.elements.filter((e) => (e.props as { state?: string }).state === 'docked')).toHaveLength(1)
  expect(layer.unplaced.map((p) => p.groupId)).toEqual(['g2'])
  expect(layer.unplaced[0].at).toBeNull()
})

import { test, expect } from '@playwright/test'
import {
  resolveTeamMarkers,
  resolveTeamDockBadges,
  resolveFleetSpaceBadges,
  resolveFleetCombatBadges,
  teamMarkersLayer,
  TeamMovingMarkers,
  TeamMarkerBadge,
  TeamDockBadge,
  TeamCombatBadge,
} from '../src/features/map/teamMarkers'
import { interpolateMovementPoint } from '../src/features/map/movementInterpolation'
import type { FleetMovement } from '../src/features/fleets/fleetTypes'
import type { GroupRow } from '../src/features/command/teamRoster'
import type { DockedTeamRollup } from '../src/features/command/teamRollup'
// type-only import — erased at compile, so the spec never loads teamApi's supabase client.
import type { UnifiedGroupFleetLite } from '../src/features/command/teamApi'
import type { FleetEncounterLite } from '../src/features/combat/encounterAnchor'
import type { CombatUnit } from '../src/features/combat/combatTypes'

// TEAMMAP-2 — pure specs for the team-marker cluster function + the shared movement interpolation,
// and the GalaxyMap wiring proof via the SAME pure `teamMarkersLayer` element-descriptor helper the
// map renders (the galaxyShipLayer.spec.ts convention). No hooks run, no DB, no fabricated backend.

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

const groups: GroupRow[] = [
  { group_id: 'g1', group_index: 1, name: 'Alpha' },
  { group_id: 'g2', group_index: 2, name: 'Bravo' },
]

// ── interpolateMovementPoint — the ONE shared clamp-lerp ────────────────────────────────────────────
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

// ── resolveTeamMarkers — the pure cluster function ──────────────────────────────────────────────────
test('multi-fleet group (expedition): ONE badge at the LEAD (earliest-ETA) fleet, labeled with the ship count', () => {
  const early = mv({ id: 'm-early', fleet_id: 'f1', group_id: 'g1', arrive_at: '2026-01-01T00:05:00Z' })
  const late = mv({ id: 'm-late', fleet_id: 'f2', group_id: 'g1', arrive_at: ARR, origin_x: 900, origin_y: 900, target_x: 999, target_y: 999 })
  const out = resolveTeamMarkers([late, early], groups, midMs)
  expect(out).toHaveLength(1)
  expect(out[0].groupId).toBe('g1')
  expect(out[0].label).toBe('Fleet Alpha · 2 ships')
  expect(out[0].fleetCount).toBe(2)
  expect(out[0].arriveAt).toBe('2026-01-01T00:05:00Z')
  // position = the lead's interpolated point, via the SAME shared helper
  expect({ x: out[0].x, y: out[0].y }).toEqual(interpolateMovementPoint(early, midMs))
})

test('single-fleet group (hunt): badge at the fleet interpolated position, bare fleet label', () => {
  const out = resolveTeamMarkers([mv({ group_id: 'g2' })], groups, midMs)
  expect(out).toHaveLength(1)
  expect(out[0].label).toBe('Fleet Bravo')
  expect({ x: out[0].x, y: out[0].y }).toEqual({ x: 50, y: 100 })
})

test('fail closed: untagged, non-moving, unknown-group, and incoherent-lead movements produce no badge', () => {
  const out = resolveTeamMarkers(
    [
      mv({ id: 'a', group_id: null }), // untagged (solo send)
      mv({ id: 'b', group_id: 'g1', status: 'arrived' }), // not moving
      mv({ id: 'c', group_id: 'ghost' }), // tag points at a group not in the owner read
      mv({ id: 'd', group_id: 'g2', arrive_at: DEP }), // incoherent segment (arr <= dep)
    ],
    groups,
    midMs,
  )
  expect(out).toEqual([])
})

test('zero groups → no markers regardless of tags (the dark posture)', () => {
  expect(resolveTeamMarkers([mv({ group_id: 'g1' })], [], midMs)).toEqual([])
})

test('two teams in flight → one badge each, deterministic (groupId) order', () => {
  const out = resolveTeamMarkers(
    [mv({ id: 'x', fleet_id: 'f1', group_id: 'g2' }), mv({ id: 'y', fleet_id: 'f2', group_id: 'g1' })],
    groups,
    midMs,
  )
  expect(out.map((m) => m.groupId)).toEqual(['g1', 'g2'])
})

test('equal ETAs tie-break on movement id (stable lead across re-renders)', () => {
  const a = mv({ id: 'aaa', fleet_id: 'f1', group_id: 'g1', origin_x: 0, origin_y: 0, target_x: 10, target_y: 10 })
  const b = mv({ id: 'bbb', fleet_id: 'f2', group_id: 'g1', origin_x: 500, origin_y: 500, target_x: 510, target_y: 510 })
  const out1 = resolveTeamMarkers([a, b], groups, midMs)
  const out2 = resolveTeamMarkers([b, a], groups, midMs)
  expect(out1).toEqual(out2)
  expect({ x: out1[0].x, y: out1[0].y }).toEqual(interpolateMovementPoint(a, midMs))
})

// ── resolveTeamDockBadges — complete (n/n) docks only ───────────────────────────────────────────────
const rollup = (o: Partial<DockedTeamRollup> = {}): DockedTeamRollup => ({
  groupId: 'g1',
  name: 'Alpha',
  memberCount: 2,
  dockedCount: 2,
  locationId: 'loc-A',
  ...o,
})

test('dock badges: complete rollups map to "Fleet <name> n/n"; partial/split/empty produce none', () => {
  const out = resolveTeamDockBadges([
    rollup(), // complete → badge
    rollup({ groupId: 'g2', name: 'Bravo', dockedCount: 1, locationId: null }), // partial → none
    rollup({ groupId: 'g3', name: 'Empty', memberCount: 0, dockedCount: 0, locationId: null }), // empty → none
  ])
  expect(out).toEqual([{ groupId: 'g1', label: 'Fleet Alpha 2/2', locationId: 'loc-A' }])
})

// (4C-CLIENT: the deriveTeamRepresentedShipIds de-dup specs were deleted with the function — its
// only consumer, the per-ship chevron layer, was removed in S5.)

// ── teamMarkersLayer — the GalaxyMap wiring proof (element-tree convention) ─────────────────────────
// S2 TERRITORY widened the layer's location pick (name + territory_radius feed the orbit label);
// loc-A carries no territory, so every pre-S2 expectation below is byte-identical.
const locations = [{ id: 'loc-A', name: 'Alpha Port', x: 100, y: 200, territory_radius: null }]

test('layer: zero groups → [] (map byte-identical to today while TEAM_COMMAND is dark)', () => {
  expect(
    teamMarkersLayer({ movements: [mv({ group_id: 'g1' })], groups: [], rollups: [rollup()], locations, norm, k: 1 }),
  ).toEqual([])
})

test('layer: mounts TeamMovingMarkers exactly once (first, under the dock badges) with the map context', () => {
  const movements = [mv({ group_id: 'g1' })]
  const layer = teamMarkersLayer({ movements, groups, rollups: [], locations, norm, k: 2 })
  expect(layer).toHaveLength(1)
  expect(layer[0].type).toBe(TeamMovingMarkers)
  const props = layer[0].props as { movements: unknown; groups: unknown; k: number }
  expect(props.movements).toBe(movements)
  expect(props.groups).toBe(groups)
  expect(props.k).toBe(2)
})

test('layer: one TeamDockBadge per complete rollup, positioned at the port through the map norm', () => {
  const layer = teamMarkersLayer({ movements: [], groups, rollups: [rollup()], locations, norm, k: 1 })
  const badge = layer.find((e) => e.type === TeamDockBadge)
  expect(badge).toBeTruthy()
  const props = badge!.props as { groupId: string; label: string; x: number; y: number; stack: number }
  expect(props.groupId).toBe('g1')
  expect(props.label).toBe('Fleet Alpha 2/2')
  expect({ x: props.x, y: props.y }).toEqual({ x: 100, y: 200 })
  expect(props.stack).toBe(0)
})

// ── FLEET-GO 4a-1 — resolveFleetSpaceBadges: the parked-in-space fleet badge (charter §2/0208). ──
const spaceFleet = (o: Partial<UnifiedGroupFleetLite> = {}): UnifiedGroupFleetLite => ({
  id: 'fleet-g1',
  group_id: 'g1',
  status: 'idle',
  location_mode: 'space',
  current_location_id: null,
  space_x: 40,
  space_y: 60,
  ...o,
})

test('space badge: a parked unified fleet → one badge at its OWN coordinates, member count from the rollup', () => {
  const out = resolveFleetSpaceBadges([spaceFleet()], groups, [rollup({ locationId: null, dockedCount: 0 })])
  expect(out).toEqual([{ groupId: 'g1', label: 'Fleet Alpha · 2 ships', x: 40, y: 60 }])
})

test('space badge: single-member (or unknown-count) fleets take the bare label', () => {
  const out = resolveFleetSpaceBadges([spaceFleet()], groups, [rollup({ memberCount: 1, dockedCount: 0, locationId: null })])
  expect(out[0].label).toBe('Fleet Alpha')
  // no rollup row for the group at all → still a badge, bare label (fail soft on the count only)
  expect(resolveFleetSpaceBadges([spaceFleet()], groups, [])[0].label).toBe('Fleet Alpha')
})

test('space badge: fail closed — non-space modes, missing coords, unknown groups, zero groups → nothing', () => {
  expect(resolveFleetSpaceBadges([spaceFleet({ location_mode: 'location' })], groups, [])).toEqual([])
  expect(resolveFleetSpaceBadges([spaceFleet({ space_x: null })], groups, [])).toEqual([])
  expect(resolveFleetSpaceBadges([spaceFleet({ space_y: null })], groups, [])).toEqual([])
  expect(resolveFleetSpaceBadges([spaceFleet({ group_id: 'ghost' })], groups, [])).toEqual([])
  expect(resolveFleetSpaceBadges([spaceFleet()], [], [])).toEqual([])
})

test('space badge: one badge per group (first wins on a duplicate); deterministic order by groupId', () => {
  const out = resolveFleetSpaceBadges(
    [spaceFleet({ group_id: 'g2', space_x: 1, space_y: 2 }), spaceFleet(), spaceFleet({ space_x: 99, space_y: 99 })],
    groups,
    [],
  )
  expect(out.map((b) => b.groupId)).toEqual(['g1', 'g2'])
  expect(out[0]).toMatchObject({ x: 40, y: 60 }) // the duplicate's coords never overwrite the first
})

// ── S2 TERRITORY — the "in orbit of X" label extension (territoryAt composed, ONE distance()) ──
test('space badge: parked inside a territory → the label extends with "in orbit of X"', () => {
  const locs = [{ id: 'loc-T', name: 'Slagworks Anchorage', x: 45, y: 60, territory_radius: 25 }]
  const out = resolveFleetSpaceBadges([spaceFleet()], groups, [rollup({ locationId: null, dockedCount: 0 })], locs)
  expect(out[0].label).toBe('Fleet Alpha · 2 ships · in orbit of Slagworks Anchorage')
  // bare-label form extends the same way
  expect(resolveFleetSpaceBadges([spaceFleet()], groups, [], locs)[0].label).toBe('Fleet Alpha · in orbit of Slagworks Anchorage')
})

test('space badge: outside every territory, or a NULL-territory world, keeps the plain label', () => {
  const far = [{ id: 'loc-T', name: 'Slagworks Anchorage', x: 500, y: 500, territory_radius: 25 }]
  expect(resolveFleetSpaceBadges([spaceFleet()], groups, [], far)[0].label).toBe('Fleet Alpha')
  const nul = [{ id: 'loc-T', name: 'Slagworks Anchorage', x: 45, y: 60, territory_radius: null }]
  expect(resolveFleetSpaceBadges([spaceFleet()], groups, [], nul)[0].label).toBe('Fleet Alpha')
  // omitting the locations arg entirely is the pre-S2 call — byte-identical
  expect(resolveFleetSpaceBadges([spaceFleet()], groups, [])[0].label).toBe('Fleet Alpha')
})

test('layer: a parked unified fleet renders a TeamMarkerBadge under the fleet-space testid, through the map norm', () => {
  const layer = teamMarkersLayer({
    movements: [],
    groups,
    rollups: [],
    locations,
    norm: (p) => ({ x: p.x + 1, y: p.y + 1 }), // non-identity: proves projection happens
    k: 1,
    unifiedFleets: [spaceFleet()],
  })
  const badge = layer.find((e) => e.type === TeamMarkerBadge)
  expect(badge).toBeTruthy()
  const props = badge!.props as { groupId: string; label: string; x: number; y: number; testIdPrefix?: string }
  expect(props.groupId).toBe('g1')
  expect(props.testIdPrefix).toBe('fleet-space-badge')
  expect({ x: props.x, y: props.y }).toEqual({ x: 41, y: 61 })
})

test('layer: omitting unifiedFleets leaves the tree byte-identical (dark parity for the map)', () => {
  const base = { movements: [], groups, rollups: [rollup()], locations, norm, k: 1 }
  expect(teamMarkersLayer({ ...base, unifiedFleets: [] })).toEqual(teamMarkersLayer(base))
})

// ── MAP-INTEGRATION M1 — resolveFleetCombatBadges: the in-combat fleet badge ─────────────────────
// A group fleet 'present' at a combat site is stripped from the dock fold (correct), has no moving
// movement and no space park — without THIS badge it is invisible for the whole combat phase. Input
// is the pre-partitioned combat set (teamRollup.selectCombatSortieFleets); position is the SITE's.
const combatFleet = (o: Partial<UnifiedGroupFleetLite> = {}): UnifiedGroupFleetLite => ({
  id: 'fleet-g1',
  group_id: 'g1',
  status: 'present',
  location_mode: 'location',
  current_location_id: 'loc-A',
  space_x: null,
  space_y: null,
  ...o,
})

test('combat badge: a combat-present fleet → one badge AT the site, labeled "in combat at X" with the member count', () => {
  const out = resolveFleetCombatBadges([combatFleet()], groups, [rollup({ locationId: null, dockedCount: 0 })], locations)
  expect(out).toEqual([
    { groupId: 'g1', label: 'Fleet Alpha · 2 ships · in combat at Alpha Port', locationId: 'loc-A', x: 100, y: 200 },
  ])
})

test('combat badge: single-member (or unknown-count) fleets take the bare label form', () => {
  const one = resolveFleetCombatBadges([combatFleet()], groups, [rollup({ memberCount: 1, dockedCount: 0, locationId: null })], locations)
  expect(one[0].label).toBe('Fleet Alpha · in combat at Alpha Port')
  expect(resolveFleetCombatBadges([combatFleet()], groups, [], locations)[0].label).toBe('Fleet Alpha · in combat at Alpha Port')
})

test('combat badge: fail closed — non-present status, no location, unknown group, unrevealed site, zero groups', () => {
  expect(resolveFleetCombatBadges([combatFleet({ status: 'moving' })], groups, [], locations)).toEqual([])
  expect(resolveFleetCombatBadges([combatFleet({ current_location_id: null })], groups, [], locations)).toEqual([])
  expect(resolveFleetCombatBadges([combatFleet({ group_id: 'ghost' })], groups, [], locations)).toEqual([])
  expect(resolveFleetCombatBadges([combatFleet({ current_location_id: 'loc-hidden' })], groups, [], locations)).toEqual([]) // no id leak
  expect(resolveFleetCombatBadges([combatFleet()], [], [], locations)).toEqual([])
})

test('combat badge: one badge per group (first wins on a duplicate); deterministic order by groupId', () => {
  const out = resolveFleetCombatBadges(
    [combatFleet({ group_id: 'g2' }), combatFleet(), combatFleet()],
    groups,
    [],
    locations,
  )
  expect(out.map((b) => b.groupId)).toEqual(['g1', 'g2'])
})

// ── THE FLEET STANDS ON A REAL SHIP — the badge must not be a second copy of the fleet ────────────
// The owner, first: "when fighting, my fleet location and the fighting location differs". The badge
// sat on the fleet's parked point while its own ships — drawn by spatialCombatLayer from
// combat_units.pos_x/pos_y — were 20-30 units away. One fleet, two places. The first fix moved the
// badge to the CENTROID of those ships, and the owner, after it shipped: "the fleet arrived at
// combat zone, it fights but in a different location. This is not fixed."
//
// The fixture below IS that production fight, measured: 3 enemy units on EXACTLY one point 5.0 from
// the engagement anchor, 4 player ships scattered 20.7-28.1 from it. Their centroid is (-26.15,
// 113.475) — a point with NO SHIP ON IT, ~16.3 from the enemy stack, while the shooting happens at
// the stack. The badge must land on Sparrow V (-11.4, 99.0), 15.70 out: the point of attack.
// (Distances to the enemy stack: Sparrow 15.70 · p2 21.60 · p3 26.01 · p4 27.45.)
//
// ⚑ AND IT IS THE SPACE BADGE THAT DRAWS IT. An ambush parks the fleet with fleet_set_in_space
// (0301:1109 → 0231:1157-1161): status 'idle', location_mode 'space', current_location_id NULL. So
// teamRollup.isCombatSortiePresence (:103-105, which demands 'present' + a location) rejects it and
// resolveFleetCombatBadges NEVER SEES IT — verified in prod, where all eight of the owner's
// off-centre encounters are idle/space/no-location. Both resolvers are proven here anyway: they
// share one rule, and the deliberate-hunt path drifts identically once 0313/0314 move the units.
const PARK = { x: -31.968, y: 96.627 } // space_x/space_y == the engagement anchor on the ambush arm
const ENEMY = { x: -27.0, y: 97.2 } // the three enemy units, all on this one point, 5.0 from PARK
const ATTACK = { x: -11.4, y: 99.0 } // Sparrow V — the hull nearest the enemy: where the badge goes
const CENTROID = { x: -26.15, y: 113.475 } // the previous answer: empty space between the ships
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
// The owner's four real ships. Sparrow V is nearest BOTH the enemy stack and the anchor here, so the
// same hull is correct whether or not `enemies()` is supplied — the two rules are told apart in
// tests/fleetFightPosition.spec.ts, which owns the rule; these specs own the WIRING.
const formation = (over: Partial<CombatUnit> = {}): CombatUnit[] => [
  unit({ id: 'p1-sparrow', pos_x: ATTACK.x, pos_y: ATTACK.y, ...over }),
  unit({ id: 'p2-kite', pos_x: -17.5, pos_y: 116.6, ...over }),
  unit({ id: 'p3-far', pos_x: -47.1, pos_y: 113.7, ...over }),
  unit({ id: 'p4-rear', pos_x: -28.6, pos_y: 124.6, ...over }),
]
// The enemy stack is the distance TARGET and never a position. If it ever leaked into the answer the
// badge would land on it — that is what makes this fixture a real guard, not decoration.
const enemies = (): CombatUnit[] =>
  ['e-a', 'e-b', 'e-c'].map((id) => unit({ id, side: 'enemy', pos_x: ENEMY.x, pos_y: ENEMY.y }))
const enc = (o: Partial<FleetEncounterLite> = {}): FleetEncounterLite => ({
  id: 'e1',
  fleet_id: 'fleet-g1',
  status: 'active',
  ...o,
})
const parkedFleet = (o: Partial<UnifiedGroupFleetLite> = {}): UnifiedGroupFleetLite =>
  spaceFleet({ space_x: PARK.x, space_y: PARK.y, ...o })
// the group's rollup — supplies the "· 2 ships" member count, exactly as the sibling specs do
const crew = () => [rollup({ locationId: null, dockedCount: 0 })]

test('space badge: an AMBUSHED fleet badges the SHIP at the point of attack, not its parked point', () => {
  const out = resolveFleetSpaceBadges([parkedFleet()], groups, crew(), [], [enc()], [...formation(), ...enemies()])
  expect(out).toHaveLength(1)
  // THE FIRST BUG: this used to be PARK — 20-28 units from the fleet's own ships.
  expect({ x: out[0].x, y: out[0].y }).not.toEqual(PARK)
  // THE SECOND BUG: and then it was the CENTROID — a point where no ship of theirs is standing.
  expect({ x: out[0].x, y: out[0].y }).not.toEqual(CENTROID)
  expect({ x: out[0].x, y: out[0].y }).toEqual(ATTACK)
  expect(out[0].label).toBe('Fleet Alpha · 2 ships · in combat')
})

test('space badge: the drawn point IS one of the fleet’s own ships — membership, not proximity', () => {
  const ships = formation()
  const [badge] = resolveFleetSpaceBadges([parkedFleet()], groups, [], [], [enc()], [...ships, ...enemies()])
  expect(ships.map((u) => `${u.pos_x},${u.pos_y}`)).toContain(`${badge.x},${badge.y}`)
  // …and never the enemy stack it was measured against
  expect({ x: badge.x, y: badge.y }).not.toEqual(ENEMY)
})

test('space badge: only LIVING, POSITIONED, PLAYER ships of THIS encounter can take the badge', () => {
  const at = (units: CombatUnit[]) =>
    resolveFleetSpaceBadges([parkedFleet()], groups, [], [], [enc()], units)[0]
  const base = [...formation(), ...enemies()]
  // each intruder below sits ON the enemy stack (it would win outright if it were eligible)
  // a destroyed ship has no glyph, so it cannot carry the badge either
  expect({ ...at([...base, unit({ id: 'a-dead', alive_count: 0, pos_x: ENEMY.x, pos_y: ENEMY.y })]) })
    .toMatchObject(ATTACK)
  // an unpositioned (aggregate) row cannot be stood on
  expect({ ...at([...base, unit({ id: 'a-flat', pos_x: null, pos_y: null })]) }).toMatchObject(ATTACK)
  // another encounter's ships never drag this fleet
  expect({ ...at([...base, unit({ id: 'a-other', encounter_id: 'e-other', pos_x: ENEMY.x, pos_y: ENEMY.y })]) })
    .toMatchObject(ATTACK)
  // an enemy is the TARGET, never the answer
  expect({ ...at(base) }).toMatchObject(ATTACK)
})

test('space badge: fighting with NO positioned ship keeps the parked point but still says "in combat"', () => {
  const [badge] = resolveFleetSpaceBadges([parkedFleet()], groups, crew(), [], [enc()], [
    unit({ pos_x: null, pos_y: null }),
  ])
  expect({ x: badge.x, y: badge.y }).toEqual(PARK)
  expect(badge.label).toBe('Fleet Alpha · 2 ships · in combat')
})

test('space badge: no live fight → the parked point and today’s label, exactly', () => {
  const base = resolveFleetSpaceBadges([parkedFleet()], groups, crew())[0]
  expect({ x: base.x, y: base.y }).toEqual(PARK)
  expect(base.label).toBe('Fleet Alpha · 2 ships')
  // an ENDED encounter is not a live fight; another fleet's encounter is not this fleet's
  for (const e of [enc({ status: 'defeat' }), enc({ status: 'escaped' }), enc({ fleet_id: 'someone-else' })]) {
    const [b] = resolveFleetSpaceBadges([parkedFleet()], groups, crew(), [], [e], formation())
    expect({ x: b.x, y: b.y }).toEqual(PARK)
    expect(b.label).toBe('Fleet Alpha · 2 ships')
  }
})

test('space badge: the place name follows the DRAWN point, and reads as combat while fighting', () => {
  // a territory centred on the CHOSEN SHIP, not on the park: only a badge that actually moved is inside
  const terr = [{ id: 'loc-T', name: 'Snare', x: ATTACK.x, y: ATTACK.y, territory_radius: 5 }]
  const [fighting] = resolveFleetSpaceBadges([parkedFleet()], groups, crew(), terr, [enc()], formation())
  expect(fighting.label).toBe('Fleet Alpha · 2 ships · in combat near Snare')
  // at rest the same fleet is outside that territory, so it keeps the plain label
  const [resting] = resolveFleetSpaceBadges([parkedFleet()], groups, crew(), terr)
  expect(resting.label).toBe('Fleet Alpha · 2 ships')
  // …and a resting fleet INSIDE a territory still reads "in orbit of X" (unchanged)
  const home = [{ id: 'loc-T', name: 'Snare', x: PARK.x, y: PARK.y, territory_radius: 5 }]
  expect(resolveFleetSpaceBadges([parkedFleet()], groups, crew(), home)[0].label).toBe(
    'Fleet Alpha · 2 ships · in orbit of Snare',
  )
})

test('combat badge: the deliberate-hunt path obeys the SAME rule (0234 seeds at the centre, 0313/0314 move)', () => {
  // The owner's production fight, translated so its anchor lands on loc-A's centre (100,200) —
  // exactly the geometry the hunt arm produces once a few ticks of movement have run.
  const site = { x: 100, y: 200 }
  const onSite = (u: CombatUnit): CombatUnit => ({
    ...u,
    pos_x: (u.pos_x as number) - PARK.x + site.x,
    pos_y: (u.pos_y as number) - PARK.y + site.y,
  })
  const units = [...formation(), ...enemies()].map(onSite)
  const [badge] = resolveFleetCombatBadges([combatFleet()], groups, [], locations, [enc()], units)
  const expected = { x: ATTACK.x - PARK.x + site.x, y: ATTACK.y - PARK.y + site.y }
  expect({ x: badge.x, y: badge.y }).toEqual(expected)
  expect({ x: badge.x, y: badge.y }).not.toEqual(site) // not the centre it used to be pinned to
  expect({ x: badge.x, y: badge.y }).not.toEqual({
    x: CENTROID.x - PARK.x + site.x,
    y: CENTROID.y - PARK.y + site.y,
  }) // and not the centroid either — no ship stands there
  // the drawn point IS one of this fleet's ships
  expect(units.map((u) => `${u.pos_x},${u.pos_y}`)).toContain(`${badge.x},${badge.y}`)
  // the SITE still owns the label and the stacking key — the player must still know where they are
  expect(badge.label).toBe('Fleet Alpha · in combat at Alpha Port')
  expect(badge.locationId).toBe('loc-A')
})

test('combat badge: no fight, no positioned ship, or a foreign encounter → the site centre, unchanged', () => {
  const centre = { x: 100, y: 200 }
  expect(resolveFleetCombatBadges([combatFleet()], groups, [], locations)[0]).toMatchObject(centre)
  expect(
    resolveFleetCombatBadges([combatFleet()], groups, [], locations, [enc()], [unit({ pos_x: null, pos_y: null })])[0],
  ).toMatchObject(centre)
  expect(
    resolveFleetCombatBadges([combatFleet()], groups, [], locations, [enc({ fleet_id: 'nope' })], formation())[0],
  ).toMatchObject(centre)
})

test('fail closed: an unusable resting point renders NO badge — never NaN, never (0,0)', () => {
  // a site with a NaN coordinate drops the combat badge outright
  const nanSite = [{ id: 'loc-A', name: 'Alpha Port', x: Number.NaN, y: 200, territory_radius: null }]
  expect(resolveFleetCombatBadges([combatFleet()], groups, [], nanSite, [enc()], formation())).toEqual([])
  expect(resolveFleetCombatBadges([combatFleet()], groups, [], nanSite)).toEqual([])
  // the space badge already refuses a non-finite park, fighting or not
  expect(resolveFleetSpaceBadges([parkedFleet({ space_x: Number.NaN })], groups, [], [], [enc()], formation())).toEqual(
    [],
  )
  // and every badge it DOES emit carries finite, non-origin coordinates
  for (const b of resolveFleetSpaceBadges([parkedFleet()], groups, [], [], [enc()], formation())) {
    expect(Number.isFinite(b.x) && Number.isFinite(b.y)).toBe(true)
    expect(b.x === 0 && b.y === 0).toBe(false)
  }
})

// COVERAGE PIN (re-review). The two layer specs below must BOTH exist — one per badge arm. The
// re-review killed a mutant that stopped forwarding `encounters`/`units` to the SPACE arm, but the
// identical mutant on the COMBAT arm SURVIVED the entire suite: the previous round had deleted the only
// spec that rendered a combat fleet with the data wired, so nothing noticed the combat badge silently
// falling back to the site centre. Runtime was correct throughout; the guard was not. Do NOT fold these
// into one spec — a single fixture exercising one arm is exactly how the hole opened.
test('layer: the wired encounters + units move the COMBAT badge onto its lead SHIP, through the map norm', () => {
  const layer = teamMarkersLayer({
    movements: [],
    groups,
    rollups: crew(),
    locations,
    norm: (p) => ({ x: p.x + 1, y: p.y + 1 }), // non-identity: proves projection happens
    k: 1,
    combatFleets: [combatFleet()],
    encounters: [enc()], // enc().fleet_id === combatFleet().id
    units: [...formation(), ...enemies()],
  })
  const badge = layer.find((e) => e.type === TeamCombatBadge)
  expect(badge).toBeTruthy()
  const props = badge!.props as { x: number; y: number; label: string }
  // NOT the site centre (100, 200) this used to be pinned to, and not an un-normed position either.
  expect({ x: props.x, y: props.y }).toEqual({ x: ATTACK.x + 1, y: ATTACK.y + 1 })
  expect(props.label).toBe('Fleet Alpha · 2 ships · in combat at Alpha Port')
})

test('layer: the wired encounters + units move the SPACE badge onto its lead SHIP, through the map norm', () => {
  const layer = teamMarkersLayer({
    movements: [],
    groups,
    rollups: [],
    locations,
    norm: (p) => ({ x: p.x + 1, y: p.y + 1 }), // non-identity: proves projection happens
    k: 1,
    unifiedFleets: [parkedFleet()],
    encounters: [enc()],
    units: formation(),
  })
  const space = layer.find((e) => e.type === TeamMarkerBadge)
  expect(space).toBeTruthy()
  const props = space!.props as { x: number; y: number; label: string; testIdPrefix?: string }
  expect(props.testIdPrefix).toBe('fleet-space-badge')
  expect({ x: props.x, y: props.y }).toEqual({ x: ATTACK.x + 1, y: ATTACK.y + 1 })
  expect(props.label).toBe('Fleet Alpha · in combat')
})

test('layer: omitting encounters/units leaves the tree byte-identical (every badge at rest)', () => {
  const base = {
    movements: [mv({ group_id: 'g1' })],
    groups,
    rollups: [rollup()],
    locations,
    norm,
    k: 1,
    unifiedFleets: [parkedFleet()],
    combatFleets: [combatFleet({ group_id: 'g2', id: 'fleet-g2' })],
  }
  expect(teamMarkersLayer({ ...base, encounters: [], units: [] })).toEqual(teamMarkersLayer(base))
})

test('layer: a fighting fleet is claimed by the SPACE arm only — the combat arm never also badges it', () => {
  const layer = teamMarkersLayer({
    movements: [mv({ group_id: 'g1' })], // a movement row for the same group…
    groups,
    rollups: [rollup()], // …and a docked rollup for it too
    locations,
    norm,
    k: 1,
    unifiedFleets: [parkedFleet()],
    combatFleets: [],
    encounters: [enc()],
    units: formation(),
  })
  // The space badge is the fleet's ONE representation among the badges rendered at THIS level.
  // Scope, stated honestly: `TeamMovingMarkers` is element 0 of this same array and renders its own
  // TeamMarkerBadge for g1 when mounted, which a filter over the top level cannot see — so this spec
  // does NOT prove "never drawn twice" in the DOM. The double-draw is unreachable in prod for a
  // different reason (0301:1104 cancels the movement, and 0231:1335 sets location_mode='movement'
  // while moving, which teamMarkers.ts:155 rejects), and that is an invariant of the SERVER, not of
  // this fixture. What this spec does prove: the space arm claims g1 and the combat arm does not.
  const spaceBadges = layer.filter((e) => e.type === TeamMarkerBadge)
  expect(spaceBadges).toHaveLength(1)
  expect((spaceBadges[0].props as { groupId: string }).groupId).toBe('g1')
  expect(layer.filter((e) => e.type === TeamCombatBadge)).toHaveLength(0)
})

test('layer: a combat-present fleet renders a TeamCombatBadge at the site through the map norm', () => {
  const layer = teamMarkersLayer({
    movements: [],
    groups,
    rollups: [],
    locations,
    norm: (p) => ({ x: p.x + 1, y: p.y + 1 }), // non-identity: proves projection happens
    k: 1,
    combatFleets: [combatFleet()],
  })
  const badge = layer.find((e) => e.type === TeamCombatBadge)
  expect(badge).toBeTruthy()
  const props = badge!.props as { groupId: string; label: string; x: number; y: number; stack: number }
  expect(props.groupId).toBe('g1')
  expect(props.label).toBe('Fleet Alpha · in combat at Alpha Port')
  expect({ x: props.x, y: props.y }).toEqual({ x: 101, y: 201 })
  expect(props.stack).toBe(0)
})

test('layer: co-fighting teams at one site STACK their combat labels', () => {
  const layer = teamMarkersLayer({
    movements: [],
    groups,
    rollups: [],
    locations,
    norm,
    k: 1,
    combatFleets: [combatFleet(), combatFleet({ group_id: 'g2' })],
  })
  const badges = layer.filter((e) => e.type === TeamCombatBadge)
  expect(badges.map((b) => (b.props as { stack: number }).stack)).toEqual([0, 1])
})

test('layer: omitting combatFleets leaves the tree byte-identical (dark parity — dock/moving/space badges untouched)', () => {
  const base = { movements: [mv({ group_id: 'g1' })], groups, rollups: [rollup()], locations, norm, k: 1, unifiedFleets: [spaceFleet()] }
  expect(teamMarkersLayer({ ...base, combatFleets: [] })).toEqual(teamMarkersLayer(base))
  // and the normal markers still render alongside a combat badge (nothing suppressed)
  const withCombat = teamMarkersLayer({ ...base, combatFleets: [combatFleet({ group_id: 'g2' })] })
  expect(withCombat.some((e) => e.type === TeamMovingMarkers)).toBe(true)
  expect(withCombat.some((e) => e.type === TeamDockBadge)).toBe(true)
  expect(withCombat.some((e) => e.type === TeamMarkerBadge)).toBe(true) // the in-space badge
  expect(withCombat.some((e) => e.type === TeamCombatBadge)).toBe(true)
})

test('layer: co-docked teams stack; a rollup at an unrevealed location renders no badge (fail closed)', () => {
  const layer = teamMarkersLayer({
    movements: [],
    groups,
    rollups: [
      rollup(),
      rollup({ groupId: 'g2', name: 'Bravo' }), // same port → stacked
      rollup({ groupId: 'g3', name: 'Ghost', locationId: 'loc-unseen' }), // not in world read → none
    ],
    locations,
    norm,
    k: 1,
  })
  const badges = layer.filter((e) => e.type === TeamDockBadge)
  expect(badges.map((b) => (b.props as { stack: number }).stack)).toEqual([0, 1])
  expect(badges.some((b) => (b.props as { groupId: string }).groupId === 'g3')).toBe(false)
})

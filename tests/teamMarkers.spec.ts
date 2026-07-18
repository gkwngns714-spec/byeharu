import { test, expect } from '@playwright/test'
import {
  resolveTeamMarkers,
  resolveTeamDockBadges,
  resolveFleetSpaceBadges,
  resolveFleetCombatBadges,
  teamMarkersLayer,
  deriveTeamRepresentedShipIds,
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

// ── deriveTeamRepresentedShipIds — the FLEETMAP de-dup set (which ships a team marker already draws) ──
test('de-dup: members of a COMPLETE docked team (its dock badge) are represented', () => {
  const ids = deriveTeamRepresentedShipIds({
    membership: { s1: { group_id: 'g1' }, s2: { group_id: 'g1' }, solo: { group_id: null } },
    rollups: [rollup()], // g1 complete (n/n) → dock badge drawn
    movements: [],
    groups,
    nowMs: midMs,
  })
  expect([...ids].sort()).toEqual(['s1', 's2'])
})

test('de-dup: members of an IN-FLIGHT moving team (its moving badge) are represented', () => {
  const ids = deriveTeamRepresentedShipIds({
    membership: { s1: { group_id: 'g2' }, s2: { group_id: 'g2' } },
    rollups: [],
    movements: [mv({ group_id: 'g2' })], // g2 moving → moving badge drawn
    groups,
    nowMs: midMs,
  })
  expect([...ids].sort()).toEqual(['s1', 's2'])
})

test('de-dup: a ship in NO marked group (solo, or a partial/incoherent team) keeps its own chevron', () => {
  const ids = deriveTeamRepresentedShipIds({
    membership: { solo: { group_id: null }, partial: { group_id: 'g2' } },
    rollups: [rollup({ groupId: 'g2', name: 'Bravo', dockedCount: 1, locationId: null })], // partial → no badge
    movements: [], // g2 not in flight either
    groups,
    nowMs: midMs,
  })
  expect(ids.size).toBe(0)
})

test('de-dup: no groups / no markers → empty set (dark posture; every ship keeps its chevron)', () => {
  expect(
    deriveTeamRepresentedShipIds({ membership: { s1: { group_id: 'g1' } }, rollups: [], movements: [], groups: [], nowMs: midMs }).size,
  ).toBe(0)
})

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

test('de-dup: members of an IN-SPACE parked fleet are represented (chevrons suppressed under the badge)', () => {
  const ids = deriveTeamRepresentedShipIds({
    membership: { s1: { group_id: 'g1' }, s2: { group_id: 'g1' }, solo: { group_id: null } },
    rollups: [],
    movements: [],
    groups,
    nowMs: midMs,
    unifiedFleets: [spaceFleet()],
  })
  expect([...ids].sort()).toEqual(['s1', 's2'])
})

test('de-dup: omitting unifiedFleets is byte-identical to the pre-slice call (dark parity)', () => {
  const args = {
    membership: { s1: { group_id: 'g1' } },
    rollups: [rollup()],
    movements: [] as FleetMovement[],
    groups,
    nowMs: midMs,
  }
  expect([...deriveTeamRepresentedShipIds(args)]).toEqual([...deriveTeamRepresentedShipIds({ ...args, unifiedFleets: [] })])
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

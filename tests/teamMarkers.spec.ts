import { test, expect } from '@playwright/test'
import {
  resolveTeamMarkers,
  resolveTeamDockBadges,
  teamMarkersLayer,
  TeamMovingMarkers,
  TeamDockBadge,
} from '../src/features/map/teamMarkers'
import { interpolateMovementPoint } from '../src/features/map/movementInterpolation'
import type { FleetMovement } from '../src/features/fleets/fleetTypes'
import type { GroupRow } from '../src/features/command/teamRoster'
import type { DockedTeamRollup } from '../src/features/command/teamRollup'

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
  expect(out[0].label).toBe('Team Alpha · 2 ships')
  expect(out[0].fleetCount).toBe(2)
  expect(out[0].arriveAt).toBe('2026-01-01T00:05:00Z')
  // position = the lead's interpolated point, via the SAME shared helper
  expect({ x: out[0].x, y: out[0].y }).toEqual(interpolateMovementPoint(early, midMs))
})

test('single-fleet group (hunt): badge at the fleet interpolated position, bare team label', () => {
  const out = resolveTeamMarkers([mv({ group_id: 'g2' })], groups, midMs)
  expect(out).toHaveLength(1)
  expect(out[0].label).toBe('Team Bravo')
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

test('dock badges: complete rollups map to "Team <name> n/n"; partial/split/empty produce none', () => {
  const out = resolveTeamDockBadges([
    rollup(), // complete → badge
    rollup({ groupId: 'g2', name: 'Bravo', dockedCount: 1, locationId: null }), // partial → none
    rollup({ groupId: 'g3', name: 'Empty', memberCount: 0, dockedCount: 0, locationId: null }), // empty → none
  ])
  expect(out).toEqual([{ groupId: 'g1', label: 'Team Alpha 2/2', locationId: 'loc-A' }])
})

// ── teamMarkersLayer — the GalaxyMap wiring proof (element-tree convention) ─────────────────────────
const locations = [{ id: 'loc-A', x: 100, y: 200 }]

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
  expect(props.label).toBe('Team Alpha 2/2')
  expect({ x: props.x, y: props.y }).toEqual({ x: 100, y: 200 })
  expect(props.stack).toBe(0)
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

import { test, expect } from '@playwright/test'
import { fitGateMessage, fittingEditability, unfittedModuleInstances } from '../src/features/ship/fittingView'
import { buildTeamRoster, fleetPositionLocationLabel, type GroupRow, type RosterShip } from '../src/features/command/teamRoster'
import type { FleetPosition } from '../src/features/map/mainshipApi'
import type { ModuleInstance, ShipFittingRow } from '../src/features/modules/modulesTypes'
import type { MapLocation } from '../src/features/map/mapTypes'

// S6 FITTING — pure-logic specs for the Fitting tab's selectors (no app/Supabase; the
// teamRoster.spec idiom). Covers the three view facts the screen derives:
//   · fit-eligibility from the ONE fleet-positions row (docked editable; berthed honestly closed
//     INTERIM-UNTIL-4C — the server's 0114 settled-safe rule rejects every berthed fit today;
//     all else closed);
//   · the unfitted module pool (fit candidates — never a module already fitted somewhere);
//   · the berthed section = buildTeamRoster's ungrouped bucket, whose rows resolve their berth
//     port through the ONE shared location fold ('berthed' → "Docked at <port>").
// Run: `npx playwright test fittingView.spec.ts`.

const pos = (over: Partial<FleetPosition> = {}): FleetPosition => ({
  main_ship_id: 's1',
  name: 'Byeharu',
  class: 'starter_frigate',
  status: 'stationary',
  spatial_state: 'at_location',
  place: 'docked',
  location_id: 'loc-haven',
  space_x: null,
  space_y: null,
  segment: null,
  ...over,
})

const loc = (over: Partial<MapLocation> = {}): MapLocation => ({
  id: 'loc-haven',
  name: 'Haven Reach',
  location_type: 'trade_outpost',
  x: 0,
  y: 0,
  base_difficulty: 1,
  reward_tier: 1,
  activity_type: 'trade_visit',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  ...over,
})

const instance = (over: Partial<ModuleInstance> = {}): ModuleInstance => ({
  instance_id: 'm1',
  module_type_id: 'cargo_lattice',
  name: 'Cargo Lattice',
  slot_type: 'utility',
  created_at: '2026-01-01T00:00:00Z',
  ...over,
})

const fitting = (over: Partial<ShipFittingRow> = {}): ShipFittingRow => ({
  module_instance_id: 'm1',
  main_ship_id: 's1',
  fitted_at: '2026-01-02T00:00:00Z',
  module_type_id: 'cargo_lattice',
  name: 'Cargo Lattice',
  slot_type: 'utility',
  slot_cost: 1,
  ...over,
})

// ── fittingEditability — the SAME-row gate (docked editable; everything else closed) ─────────────
test('fittingEditability: docked → editable', () => {
  expect(fittingEditability(pos({ place: 'docked' }))).toEqual({ editable: true, reason: null })
})

// INTERIM-UNTIL-4C: berthed is honestly NOT editable — 0114 accepts only ('home','at_location')
// and a berthed ship never validates to either, so the server rejects every attempt. When 4c
// canonicalizes berthed as settled, this flips back to editable and the reason is deleted.
test('fittingEditability: berthed (the S1 place) → closed with the honest berthed reason', () => {
  expect(fittingEditability(pos({ place: 'berthed', location_id: 'loc-haven' }))).toEqual({
    editable: false,
    reason: 'berthed_not_fittable',
  })
})

test('fittingEditability: transit / in_space / hidden → closed (not_settled)', () => {
  for (const place of ['transit', 'in_space', 'hidden'] as const) {
    expect(fittingEditability(pos({ place }))).toEqual({ editable: false, reason: 'not_settled' })
  }
})

test('fittingEditability: no projection row (dark gates / destroyed ship) → closed (position_unknown)', () => {
  expect(fittingEditability(undefined)).toEqual({ editable: false, reason: 'position_unknown' })
})

test('fitGateMessage: every reason maps to player copy (never a raw code)', () => {
  expect(fitGateMessage('position_unknown')).toMatch(/position unavailable/i)
  expect(fitGateMessage('not_settled')).toMatch(/docked at a port/i)
  // The berthed copy must tell the player HOW to fit: bring a fleet to the berth port.
  expect(fitGateMessage('berthed_not_fittable')).toMatch(/berthed/i)
  expect(fitGateMessage('berthed_not_fittable')).toMatch(/bring a fleet to its port/i)
})

// ── unfittedModuleInstances — the fit-candidate pool ─────────────────────────────────────────────
test('unfittedModuleInstances: excludes instances fitted to ANY ship, preserves order', () => {
  const instances = [
    instance({ instance_id: 'm1' }),
    instance({ instance_id: 'm2', name: 'Shield Booster' }),
    instance({ instance_id: 'm3', name: 'Mining Rig' }),
  ]
  // m1 fitted to THIS ship, m3 fitted to ANOTHER ship — only m2 is a candidate.
  const fittings = [fitting({ module_instance_id: 'm1', main_ship_id: 's1' }), fitting({ module_instance_id: 'm3', main_ship_id: 's2' })]
  expect(unfittedModuleInstances(instances, fittings).map((m) => m.instance_id)).toEqual(['m2'])
})

test('unfittedModuleInstances: no fittings → every instance is a candidate; no instances → empty', () => {
  const instances = [instance({ instance_id: 'a' }), instance({ instance_id: 'b' })]
  expect(unfittedModuleInstances(instances, []).map((m) => m.instance_id)).toEqual(['a', 'b'])
  expect(unfittedModuleInstances([], [fitting()])).toEqual([])
})

// ── the berthed section — buildTeamRoster's ungrouped bucket × the ONE location fold ─────────────
test('berthed section: ungrouped ships land in the bucket and resolve their berth port label', () => {
  const groups: GroupRow[] = [{ group_id: 'g1', group_index: 1, name: 'Alpha' }]
  const ships: RosterShip[] = [
    { main_ship_id: 'fleeted', name: 'Fleeted', status: 'stationary', group_id: 'g1' },
    { main_ship_id: 'berthed', name: 'Berthed', status: 'stationary', group_id: null },
  ]
  const { teams, ungrouped } = buildTeamRoster(groups, ships)
  expect(teams[0].ships.map((s) => s.main_ship_id)).toEqual(['fleeted'])
  expect(ungrouped.map((s) => s.main_ship_id)).toEqual(['berthed'])

  // The bucket's row resolves its location through the SAME fold every roster row uses:
  // place='berthed' → the berth port, worded as a docked read.
  const label = fleetPositionLocationLabel(
    pos({ main_ship_id: 'berthed', place: 'berthed', location_id: 'loc-haven' }),
    [loc()],
  )
  expect(label).toBe('Docked at Haven Reach')
})

test('berthed section: a dangling group_id falls to the bucket too (never silently attached)', () => {
  const { ungrouped } = buildTeamRoster(
    [],
    [{ main_ship_id: 'x', name: 'X', status: 'stationary', group_id: 'g-deleted' }],
  )
  expect(ungrouped.map((s) => s.main_ship_id)).toEqual(['x'])
})

test('location honesty: a ship absent from the projection yields null (row shows "Location unavailable")', () => {
  expect(fleetPositionLocationLabel(undefined, [loc()])).toBeNull()
})

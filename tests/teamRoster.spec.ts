import { test, expect } from '@playwright/test'
import {
  buildTeamRoster,
  resolveOwnedGroup,
  commissionAvailability,
  nextTeamSlot,
  fleetPositionLocationLabel,
  teamGatherState,
  type GroupRow,
  type RosterShip,
} from '../src/features/command/teamRoster'
import type { FleetPosition } from '../src/features/map/mainshipApi'
import type { MapLocation } from '../src/features/map/mapTypes'

// TEAM-COMMAND Slice A — pure-logic specs (no app/Supabase). Covers the three required areas:
// group ownership (resolveOwnedGroup), max-ship-cap behavior (commissionAvailability), and
// no-arbitrary-selection (buildTeamRoster never attaches a ship to a team it does not own; resolveOwnedGroup
// never returns an arbitrary group when ambiguous).

const group = (o: Partial<GroupRow> = {}): GroupRow => ({
  group_id: 'g1',
  group_index: 1,
  name: 'Alpha',
  ...o,
})

const ship = (o: Partial<RosterShip> = {}): RosterShip => ({
  main_ship_id: 's1',
  name: 'Byeharu',
  status: 'stationary',
  group_id: null,
  ...o,
})

// ── resolveOwnedGroup — ownership + fail-closed (mirrors mainship_resolve_owned_ship) ──────────────
test('resolveOwnedGroup: explicit id owned → returns it', () => {
  const groups = [group({ group_id: 'g1' }), group({ group_id: 'g2', group_index: 2 })]
  expect(resolveOwnedGroup(groups, 'g2')).toBe('g2')
})

test('resolveOwnedGroup: explicit id NOT owned → null (never trusts the caller)', () => {
  const groups = [group({ group_id: 'g1' })]
  expect(resolveOwnedGroup(groups, 'g-not-mine')).toBeNull()
})

test('resolveOwnedGroup: null id + exactly one group → the sole group', () => {
  expect(resolveOwnedGroup([group({ group_id: 'only' })], null)).toBe('only')
  expect(resolveOwnedGroup([group({ group_id: 'only' })])).toBe('only') // undefined arg = same
})

test('resolveOwnedGroup: null id + zero groups → null', () => {
  expect(resolveOwnedGroup([], null)).toBeNull()
})

test('resolveOwnedGroup: null id + MANY groups → null (never an arbitrary group)', () => {
  const groups = [
    group({ group_id: 'g1', group_index: 1 }),
    group({ group_id: 'g2', group_index: 2 }),
    group({ group_id: 'g3', group_index: 3 }),
  ]
  expect(resolveOwnedGroup(groups, null)).toBeNull()
})

// ── buildTeamRoster — grouping + no arbitrary attachment ────────────────────────────────────────
test('buildTeamRoster: buckets ships into their owned team, orders teams by group_index', () => {
  const groups = [group({ group_id: 'g2', group_index: 2, name: 'Bravo' }), group({ group_id: 'g1', group_index: 1, name: 'Alpha' })]
  const ships = [
    ship({ main_ship_id: 'a', group_id: 'g1' }),
    ship({ main_ship_id: 'b', group_id: 'g2' }),
    ship({ main_ship_id: 'c', group_id: 'g1' }),
  ]
  const view = buildTeamRoster(groups, ships)
  expect(view.teams.map((t) => t.group.group_index)).toEqual([1, 2]) // sorted ascending
  expect(view.teams[0].ships.map((s) => s.main_ship_id)).toEqual(['a', 'c']) // input order preserved
  expect(view.teams[1].ships.map((s) => s.main_ship_id)).toEqual(['b'])
  expect(view.ungrouped).toEqual([])
})

test('buildTeamRoster: null group_id → ungrouped', () => {
  const view = buildTeamRoster([group({ group_id: 'g1' })], [ship({ main_ship_id: 'x', group_id: null })])
  expect(view.ungrouped.map((s) => s.main_ship_id)).toEqual(['x'])
  expect(view.teams[0].ships).toEqual([])
})

test('buildTeamRoster: DANGLING group_id (group not owned/loaded) → ungrouped, NOT an arbitrary team', () => {
  const groups = [group({ group_id: 'g1', group_index: 1 }), group({ group_id: 'g2', group_index: 2 })]
  const view = buildTeamRoster(groups, [ship({ main_ship_id: 'ghost', group_id: 'g-deleted' })])
  expect(view.ungrouped.map((s) => s.main_ship_id)).toEqual(['ghost'])
  expect(view.teams.every((t) => t.ships.length === 0)).toBe(true) // never attached to g1 or g2
})

test('buildTeamRoster: an owned team with no ships renders as an empty team (not dropped)', () => {
  const view = buildTeamRoster([group({ group_id: 'g1', name: 'Alpha' })], [])
  expect(view.teams).toHaveLength(1)
  expect(view.teams[0].group.name).toBe('Alpha')
  expect(view.teams[0].ships).toEqual([])
})

test('buildTeamRoster: does not mutate its inputs', () => {
  const groups = [group({ group_id: 'g1' })]
  const ships = [ship({ main_ship_id: 'a', group_id: 'g1' })]
  const snap = JSON.stringify({ groups, ships })
  buildTeamRoster(groups, ships)
  expect(JSON.stringify({ groups, ships })).toBe(snap)
})

// ── commissionAvailability — cap behavior mirroring commission_additional_main_ship reject order ──
test('commissionAvailability: gate dark → gate_dark (checked BEFORE the cap)', () => {
  // Even under the cap, a dark gate wins — matches the server checking the flag before reading the cap.
  expect(commissionAvailability({ shipCount: 0, cap: 24, gateEnabled: false })).toEqual({
    canCommission: false,
    reason: 'gate_dark',
  })
})

test('commissionAvailability: gate on + at/over cap → cap_reached', () => {
  expect(commissionAvailability({ shipCount: 24, cap: 24, gateEnabled: true })).toEqual({
    canCommission: false,
    reason: 'cap_reached',
  })
  expect(commissionAvailability({ shipCount: 25, cap: 24, gateEnabled: true })).toEqual({
    canCommission: false,
    reason: 'cap_reached',
  })
})

test('commissionAvailability: gate on + under cap → ok', () => {
  expect(commissionAvailability({ shipCount: 3, cap: 24, gateEnabled: true })).toEqual({
    canCommission: true,
    reason: 'ok',
  })
})

// ── credit mirror (0091: debit AFTER gate + cap, only when price > 0) — display-only ──────────────
test('commissionAvailability: effective balance under a positive price → insufficient_credits', () => {
  expect(
    commissionAvailability({ shipCount: 1, cap: 3, gateEnabled: true, effectiveBalance: 400, price: 1000 }),
  ).toEqual({ canCommission: false, reason: 'insufficient_credits' })
})

test('commissionAvailability: credits are checked AFTER gate and cap (the 0091 server order)', () => {
  // broke AND dark → the gate reason wins; broke AND capped → the cap reason wins.
  expect(
    commissionAvailability({ shipCount: 1, cap: 3, gateEnabled: false, effectiveBalance: 0, price: 1000 }).reason,
  ).toBe('gate_dark')
  expect(
    commissionAvailability({ shipCount: 3, cap: 3, gateEnabled: true, effectiveBalance: 0, price: 1000 }).reason,
  ).toBe('cap_reached')
})

test('commissionAvailability: unknown balance/price → NO credit block (unknown must never block); price ≤ 0 is free', () => {
  // credit inputs omitted (caller has not loaded the wallet/config yet) → the old three-input behavior.
  expect(commissionAvailability({ shipCount: 1, cap: 3, gateEnabled: true })).toEqual({
    canCommission: true,
    reason: 'ok',
  })
  // 0091 skips the debit entirely when v_price ≤ 0 — a free ship never blocks on credits.
  expect(
    commissionAvailability({ shipCount: 1, cap: 3, gateEnabled: true, effectiveBalance: 0, price: 0 }),
  ).toEqual({ canCommission: true, reason: 'ok' })
})

test('commissionAvailability: exactly-affordable (balance = price) → ok (the server debit succeeds at equality)', () => {
  expect(
    commissionAvailability({ shipCount: 1, cap: 3, gateEnabled: true, effectiveBalance: 1000, price: 1000 }),
  ).toEqual({ canCommission: true, reason: 'ok' })
})

// ── nextTeamSlot — lowest free team slot 1..3, or null when capped at 3 (Slice B1) ─────────────────
test('nextTeamSlot: empty → 1', () => {
  expect(nextTeamSlot([])).toBe(1)
})

test('nextTeamSlot: fills the lowest GAP, not the next number', () => {
  expect(nextTeamSlot([group({ group_index: 1 }), group({ group_index: 3 })])).toBe(2)
  expect(nextTeamSlot([group({ group_index: 2 }), group({ group_index: 3 })])).toBe(1)
})

test('nextTeamSlot: all three slots used → null (never offers a 4th team)', () => {
  const three = [group({ group_index: 1 }), group({ group_index: 2 }), group({ group_index: 3 })]
  expect(nextTeamSlot(three)).toBeNull()
})

test('nextTeamSlot: tolerates unordered + duplicate input, stays within 1..3', () => {
  const slot = nextTeamSlot([group({ group_index: 3 }), group({ group_index: 3 }), group({ group_index: 1 })])
  expect(slot).toBe(2)
})

// ── fleetPositionLocationLabel — FLEETMAP row → the ONE leak-safe location string (TEAM-FRIENDLY) ──
const loc = (over: Partial<MapLocation> & Pick<MapLocation, 'id' | 'name'>): MapLocation => ({
  location_type: 'trade_outpost',
  x: 0,
  y: 0,
  base_difficulty: 0,
  reward_tier: 0,
  activity_type: 'trade',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  ...over,
})
const pos = (over: Partial<FleetPosition> & Pick<FleetPosition, 'main_ship_id' | 'place'>): FleetPosition => ({
  name: 'Ship',
  class: 'sloop',
  status: 'stationary',
  spatial_state: null,
  location_id: null,
  space_x: null,
  space_y: null,
  segment: null,
  ...over,
})
const world: MapLocation[] = [
  loc({ id: 'haven', name: 'Haven Reach' }),
  loc({ id: 'ember', name: 'Ember Gate', location_type: 'pirate_hunt', activity_type: 'hunt_pirates' }),
]

test('fleetPositionLocationLabel: docked → "Docked at <port>"', () => {
  expect(fleetPositionLocationLabel(pos({ main_ship_id: 's1', place: 'docked', location_id: 'haven' }), world)).toBe(
    'Docked at Haven Reach',
  )
})

test('fleetPositionLocationLabel: docked at a COMBAT site → "In combat at …" (resolver reuse)', () => {
  expect(fleetPositionLocationLabel(pos({ main_ship_id: 's1', place: 'docked', location_id: 'ember' }), world)).toBe(
    'In combat at Ember Gate',
  )
})

test('fleetPositionLocationLabel: docked at a HIDDEN port → generic "Docked", never a leaked id', () => {
  const label = fleetPositionLocationLabel(pos({ main_ship_id: 's1', place: 'docked', location_id: 'secret' }), world)
  expect(label).toBe('Docked')
  expect(label).not.toContain('secret')
})

test('fleetPositionLocationLabel: in_space → "In deep space"', () => {
  expect(fleetPositionLocationLabel(pos({ main_ship_id: 's1', place: 'in_space', space_x: 5, space_y: 5 }), world)).toBe(
    'In deep space',
  )
})

test('fleetPositionLocationLabel: transit return leg (target_kind base) → "Returning home"', () => {
  const label = fleetPositionLocationLabel(
    pos({
      main_ship_id: 's1',
      place: 'transit',
      segment: {
        origin_x: 0, origin_y: 0, target_x: 1, target_y: 1,
        target_kind: 'base', depart_at: '2026-01-01T00:00:00Z', arrive_at: '2026-01-01T00:05:00Z',
      },
    }),
    world,
  )
  expect(label).toBe('Returning home')
})

test('fleetPositionLocationLabel: outbound transit fails closed (segment has no target id) → "In transit to its destination"', () => {
  const label = fleetPositionLocationLabel(
    pos({
      main_ship_id: 's1',
      place: 'transit',
      segment: {
        origin_x: 0, origin_y: 0, target_x: 1, target_y: 1,
        target_kind: 'location', depart_at: '2026-01-01T00:00:00Z', arrive_at: '2026-01-01T00:05:00Z',
      },
    }),
    world,
  )
  expect(label).toBe('In transit to its destination')
})

test('fleetPositionLocationLabel: hidden placement or missing row → null (omit, never guess)', () => {
  expect(fleetPositionLocationLabel(pos({ main_ship_id: 's1', place: 'hidden' }), world)).toBeNull()
  expect(fleetPositionLocationLabel(undefined, world)).toBeNull()
})

// ── teamGatherState — co-location/readiness fold for the same-location notice (TEAM-FRIENDLY) ──
test('teamGatherState: no members → empty', () => {
  expect(teamGatherState({ memberCount: 0, allHome: false, dockedLocationId: null })).toBe('empty')
})

test('teamGatherState: every member docked at ONE port → co_located (from the rollup, not a second fold)', () => {
  expect(teamGatherState({ memberCount: 2, allHome: false, dockedLocationId: 'haven' })).toBe('co_located')
})

test('teamGatherState: all home (no dock) → all_home', () => {
  expect(teamGatherState({ memberCount: 2, allHome: true, dockedLocationId: null })).toBe('all_home')
})

test('teamGatherState: split ports / in transit, not all home → scattered', () => {
  expect(teamGatherState({ memberCount: 2, allHome: false, dockedLocationId: null })).toBe('scattered')
})

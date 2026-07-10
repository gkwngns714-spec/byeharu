import { test, expect } from '@playwright/test'
import {
  buildTeamRoster,
  resolveOwnedGroup,
  commissionAvailability,
  nextTeamSlot,
  type GroupRow,
  type RosterShip,
} from '../src/features/command/teamRoster'

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

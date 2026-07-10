import { test, expect } from '@playwright/test'
import { groupUpsertAvailability, assignAvailability } from '../src/features/command/teamMutations'

// TEAM-COMMAND Slice B0 — pure-logic specs for the group-write client mirror (no app/Supabase). Asserts the
// same reject ORDER as the server RPCs upsert_ship_group / assign_ship_to_group (migration 0161): the dark
// gate is checked BEFORE any other reason, and unassign (null group) is independent of owned groups.

// ── groupUpsertAvailability — mirrors upsert_ship_group ────────────────────────────────────────────
test('groupUpsertAvailability: gate dark wins even with a valid index + name', () => {
  expect(groupUpsertAvailability({ gateEnabled: false, groupIndex: 1, name: 'Alpha' })).toEqual({
    canUpsert: false,
    reason: 'gate_dark',
  })
})

test('groupUpsertAvailability: index out of 1..3 (or non-integer/null) → invalid_group_index', () => {
  for (const groupIndex of [0, 4, -1, 1.5, Number.NaN, undefined as unknown as number]) {
    expect(groupUpsertAvailability({ gateEnabled: true, groupIndex, name: 'Alpha' })).toEqual({
      canUpsert: false,
      reason: 'invalid_group_index',
    })
  }
})

test('groupUpsertAvailability: empty / whitespace / >40-char name → invalid_name', () => {
  for (const name of ['', '   ', 'x'.repeat(41)]) {
    expect(groupUpsertAvailability({ gateEnabled: true, groupIndex: 1, name })).toEqual({
      canUpsert: false,
      reason: 'invalid_name',
    })
  }
})

test('groupUpsertAvailability: 40-char and trims-to-valid names → ok', () => {
  expect(groupUpsertAvailability({ gateEnabled: true, groupIndex: 3, name: 'x'.repeat(40) }).reason).toBe('ok')
  expect(groupUpsertAvailability({ gateEnabled: true, groupIndex: 2, name: '  Alpha  ' })).toEqual({
    canUpsert: true,
    reason: 'ok',
  })
})

test('groupUpsertAvailability: order — invalid index is reported before invalid name', () => {
  // Both index and name are invalid; the index check comes first, matching the server order.
  expect(groupUpsertAvailability({ gateEnabled: true, groupIndex: 9, name: '' }).reason).toBe(
    'invalid_group_index',
  )
})

test('groupUpsertAvailability: gate is checked FIRST — dark beats an invalid index AND name', () => {
  // Pins gate-first ordering: with gate off + BOTH other inputs invalid, the answer must still be gate_dark.
  // (Guards against a refactor that moves the gate below the index/name checks.)
  expect(groupUpsertAvailability({ gateEnabled: false, groupIndex: 99, name: '' }).reason).toBe('gate_dark')
})

// ── assignAvailability — mirrors assign_ship_to_group ──────────────────────────────────────────────
test('assignAvailability: gate dark → gate_dark (before ship/group checks)', () => {
  expect(
    assignAvailability({ gateEnabled: false, shipResolved: true, groupId: 'g1', ownedGroupIds: ['g1'] }),
  ).toEqual({ canAssign: false, reason: 'gate_dark' })
})

test('assignAvailability: unresolved ship → ship_not_found', () => {
  expect(
    assignAvailability({ gateEnabled: true, shipResolved: false, groupId: 'g1', ownedGroupIds: ['g1'] }),
  ).toEqual({ canAssign: false, reason: 'ship_not_found' })
})

test('assignAvailability: a non-owned group id → group_not_found', () => {
  expect(
    assignAvailability({ gateEnabled: true, shipResolved: true, groupId: 'g-not-mine', ownedGroupIds: ['g1'] }),
  ).toEqual({ canAssign: false, reason: 'group_not_found' })
})

test('assignAvailability: assign to an owned group → ok', () => {
  expect(
    assignAvailability({ gateEnabled: true, shipResolved: true, groupId: 'g2', ownedGroupIds: ['g1', 'g2'] }),
  ).toEqual({ canAssign: true, reason: 'ok' })
})

test('assignAvailability: UNASSIGN (null group) is allowed and does NOT depend on owned groups', () => {
  // Even with zero owned groups, unassigning a resolved ship is ok — null must not route through ownership.
  expect(
    assignAvailability({ gateEnabled: true, shipResolved: true, groupId: null, ownedGroupIds: [] }),
  ).toEqual({ canAssign: true, reason: 'ok' })
})

test('assignAvailability: order — dark gate beats an unowned group', () => {
  expect(
    assignAvailability({ gateEnabled: false, shipResolved: true, groupId: 'g-not-mine', ownedGroupIds: [] })
      .reason,
  ).toBe('gate_dark')
})

test('assignAvailability: gate is checked FIRST — dark beats an unresolved ship too', () => {
  // With gate off AND ship unresolved, the answer must be gate_dark (not ship_not_found) — pins gate-first
  // ordering against a refactor that moves the ship check above the gate.
  expect(
    assignAvailability({ gateEnabled: false, shipResolved: false, groupId: null, ownedGroupIds: [] }).reason,
  ).toBe('gate_dark')
})

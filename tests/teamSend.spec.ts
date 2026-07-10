import { test, expect } from '@playwright/test'
import { groupSendAvailability } from '../src/features/command/teamSend'

// TEAM-COMMAND Slice B (sub-slice 1) — pure-logic specs for the group-send client mirror (no app/Supabase).
// Asserts the same reject ORDER as the server RPC send_ship_group_expedition (migration 0163): dark gate FIRST,
// then group resolution, then non-empty membership.

test('groupSendAvailability: gate dark → gate_dark (before group/member checks)', () => {
  // Even with a resolved, populated group, a dark gate wins — matches the server checking the flag first.
  expect(groupSendAvailability({ gateEnabled: false, groupResolved: true, memberCount: 3 })).toEqual({
    canSend: false,
    reason: 'gate_dark',
  })
})

test('groupSendAvailability: gate on + unresolved group → group_not_found', () => {
  expect(groupSendAvailability({ gateEnabled: true, groupResolved: false, memberCount: 3 })).toEqual({
    canSend: false,
    reason: 'group_not_found',
  })
})

test('groupSendAvailability: gate on + resolved + empty group → empty_group', () => {
  expect(groupSendAvailability({ gateEnabled: true, groupResolved: true, memberCount: 0 })).toEqual({
    canSend: false,
    reason: 'empty_group',
  })
})

test('groupSendAvailability: gate on + resolved + ≥1 member → ok', () => {
  expect(groupSendAvailability({ gateEnabled: true, groupResolved: true, memberCount: 1 })).toEqual({
    canSend: true,
    reason: 'ok',
  })
})

test('groupSendAvailability: order — dark gate beats an unresolved AND empty group', () => {
  // Pins gate-first ordering: with everything else also failing, the answer must still be gate_dark.
  expect(
    groupSendAvailability({ gateEnabled: false, groupResolved: false, memberCount: 0 }).reason,
  ).toBe('gate_dark')
})

test('groupSendAvailability: order — group resolution is checked before membership', () => {
  // Unresolved + empty: group_not_found (resolution) must win over empty_group.
  expect(
    groupSendAvailability({ gateEnabled: true, groupResolved: false, memberCount: 0 }).reason,
  ).toBe('group_not_found')
})

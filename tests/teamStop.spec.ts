import { test, expect } from '@playwright/test'
import { groupStopAvailability } from '../src/features/command/teamStop'

// TEAM-COMMAND Slice B (sub-slice 2) — pure-logic specs for the group-stop client mirror (no app/Supabase).
// Asserts the same PRE-READ reject ORDER as the server RPC stop_ship_group_transit (migration 0164): dark gate
// FIRST, then group resolution, then non-empty membership. (Per-member stop outcomes are the server's.)

test('groupStopAvailability: gate dark → gate_dark (before group/member checks)', () => {
  expect(groupStopAvailability({ gateEnabled: false, groupResolved: true, memberCount: 3 })).toEqual({
    canStop: false,
    reason: 'gate_dark',
  })
})

test('groupStopAvailability: gate on + unresolved group → group_not_found', () => {
  expect(groupStopAvailability({ gateEnabled: true, groupResolved: false, memberCount: 3 })).toEqual({
    canStop: false,
    reason: 'group_not_found',
  })
})

test('groupStopAvailability: gate on + resolved + empty group → empty_group', () => {
  expect(groupStopAvailability({ gateEnabled: true, groupResolved: true, memberCount: 0 })).toEqual({
    canStop: false,
    reason: 'empty_group',
  })
})

test('groupStopAvailability: gate on + resolved + ≥1 member → ok', () => {
  expect(groupStopAvailability({ gateEnabled: true, groupResolved: true, memberCount: 1 })).toEqual({
    canStop: true,
    reason: 'ok',
  })
})

test('groupStopAvailability: order — dark gate beats an unresolved AND empty group', () => {
  expect(
    groupStopAvailability({ gateEnabled: false, groupResolved: false, memberCount: 0 }).reason,
  ).toBe('gate_dark')
})

test('groupStopAvailability: order — group resolution is checked before membership', () => {
  expect(
    groupStopAvailability({ gateEnabled: true, groupResolved: false, memberCount: 0 }).reason,
  ).toBe('group_not_found')
})

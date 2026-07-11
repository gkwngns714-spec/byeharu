import { test, expect } from '@playwright/test'
import { groupSendAvailability, sendableDestinations } from '../src/features/command/teamSend'

const loc = (o: Partial<{ id: string; name: string; status: string; activity_type: string }> = {}) => ({
  id: 'l1',
  name: 'Haven',
  status: 'active',
  activity_type: 'none',
  ...o,
})

// ── sendableDestinations — active + non-combat only, projected + sorted ─────────────────────────────
test('sendableDestinations: keeps active non-combat, drops any non-"none" activity', () => {
  const out = sendableDestinations([
    loc({ id: 'a', name: 'Haven', activity_type: 'none' }),
    loc({ id: 'b', name: 'Warzone', activity_type: 'hunt_pirates' }), // combat
    loc({ id: 'c', name: 'Market', activity_type: 'trade_visit' }), // non-combat but not 'none' → still dropped
  ])
  expect(out).toEqual([{ id: 'a', name: 'Haven' }])
})

test('sendableDestinations: drops non-active even when non-combat (defensive status clause)', () => {
  expect(sendableDestinations([loc({ id: 'x', status: 'inactive', activity_type: 'none' })])).toEqual([])
})

test('sendableDestinations: projects to {id,name} and sorts by name, independent of input order', () => {
  const out = sendableDestinations([
    loc({ id: 'c', name: 'Slagworks' }),
    loc({ id: 'a', name: 'Driftmarch' }),
    loc({ id: 'b', name: 'Haven' }),
  ])
  expect(out).toEqual([
    { id: 'a', name: 'Driftmarch' },
    { id: 'b', name: 'Haven' },
    { id: 'c', name: 'Slagworks' },
  ])
})

test('sendableDestinations: empty input and all-combat input → []', () => {
  expect(sendableDestinations([])).toEqual([])
  expect(sendableDestinations([loc({ activity_type: 'mine_resource' })])).toEqual([])
})

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

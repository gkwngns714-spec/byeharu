import { test, expect } from '@playwright/test'
import { deriveDockedTeamRollups } from '../src/features/command/teamRollup'
import type { GroupRow } from '../src/features/command/teamRoster'

// TEAMMAP-0 — pure specs for the docked-team rollup fold (live membership × 'present' fleets).
// No I/O, no clock; the fixtures are plain owner-read shapes.

const groups: GroupRow[] = [
  { group_id: 'g1', group_index: 1, name: 'Alpha' },
  { group_id: 'g2', group_index: 2, name: 'Bravo' },
]

const membership = {
  s1: { group_id: 'g1' },
  s2: { group_id: 'g1' },
  s3: { group_id: 'g2' },
  s4: { group_id: null }, // ungrouped — must never count toward any team
}

test('complete dock: every member present at the SAME location → locationId set, n/n', () => {
  const out = deriveDockedTeamRollups(groups, membership, [
    { main_ship_id: 's1', current_location_id: 'port-1' },
    { main_ship_id: 's2', current_location_id: 'port-1' },
  ])
  expect(out.find((r) => r.groupId === 'g1')).toEqual({
    groupId: 'g1',
    name: 'Alpha',
    memberCount: 2,
    dockedCount: 2,
    locationId: 'port-1',
  })
})

test('partial dock: one member still away → dockedCount reported, locationId null', () => {
  const out = deriveDockedTeamRollups(groups, membership, [
    { main_ship_id: 's1', current_location_id: 'port-1' },
  ])
  expect(out.find((r) => r.groupId === 'g1')).toEqual({
    groupId: 'g1',
    name: 'Alpha',
    memberCount: 2,
    dockedCount: 1,
    locationId: null,
  })
})

test('split dock: all members present but at DIFFERENT locations → locationId null', () => {
  const out = deriveDockedTeamRollups(groups, membership, [
    { main_ship_id: 's1', current_location_id: 'port-1' },
    { main_ship_id: 's2', current_location_id: 'port-2' },
  ])
  const g1 = out.find((r) => r.groupId === 'g1')!
  expect(g1.dockedCount).toBe(2)
  expect(g1.locationId).toBeNull()
})

test('empty team: zero members → 0/0 and NO claimed dock', () => {
  const out = deriveDockedTeamRollups(groups, { s4: { group_id: null } }, [])
  expect(out.find((r) => r.groupId === 'g1')).toEqual({
    groupId: 'g1',
    name: 'Alpha',
    memberCount: 0,
    dockedCount: 0,
    locationId: null,
  })
})

test('single-member team docks alone (1/1); a null-location present fleet never counts', () => {
  const out = deriveDockedTeamRollups(groups, membership, [
    { main_ship_id: 's3', current_location_id: 'port-9' },
    { main_ship_id: 's1', current_location_id: null }, // legacy/incoherent row → not a dock
  ])
  expect(out.find((r) => r.groupId === 'g2')).toEqual({
    groupId: 'g2',
    name: 'Bravo',
    memberCount: 1,
    dockedCount: 1,
    locationId: 'port-9',
  })
  expect(out.find((r) => r.groupId === 'g1')!.dockedCount).toBe(0)
})

test('duplicate present rows for one ship: first wins, never a fabricated second dock', () => {
  const out = deriveDockedTeamRollups(groups, membership, [
    { main_ship_id: 's1', current_location_id: 'port-1' },
    { main_ship_id: 's1', current_location_id: 'port-2' }, // dupe — ignored
    { main_ship_id: 's2', current_location_id: 'port-1' },
  ])
  expect(out.find((r) => r.groupId === 'g1')!.locationId).toBe('port-1')
})

test('ungrouped ships and foreign fleets never leak into a team rollup', () => {
  const out = deriveDockedTeamRollups(groups, membership, [
    { main_ship_id: 's4', current_location_id: 'port-1' }, // ungrouped
    { main_ship_id: 'stranger', current_location_id: 'port-1' }, // not in the membership map
  ])
  expect(out.every((r) => r.dockedCount === 0 && r.locationId === null)).toBe(true)
})

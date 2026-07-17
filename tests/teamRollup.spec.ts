import { test, expect } from '@playwright/test'
import { deriveDockedTeamRollups, excludeCombatSortieFleets } from '../src/features/command/teamRollup'
import type { GroupRow } from '../src/features/command/teamRoster'
// type-only import — erased at compile, so the spec never loads teamApi's supabase client.
import type { UnifiedGroupFleetLite } from '../src/features/command/teamApi'

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

// ── FLEET-GO 4a-1 — the UNIFIED branch (charter §2: the fleet's dock IS every member's dock). ──
// The 4th input is OPTIONAL: every spec above omits it and stays untouched — that is the dark-parity
// proof (an omitted/[] unified input folds byte-identically to the pre-slice function).

const uni = (o: Partial<UnifiedGroupFleetLite> = {}): UnifiedGroupFleetLite => ({
  group_id: 'g1',
  status: 'present',
  location_mode: 'location',
  current_location_id: 'port-7',
  space_x: null,
  space_y: null,
  ...o,
})

test('UNIFIED: a present group fleet docks the WHOLE group (n/n) at its port — no per-ship rows needed', () => {
  // The members' per-ship fleets were dissolved at launch (0208), so presentFleets is EMPTY —
  // exactly the lit-world shape that used to lose the "Fleet X n/n" identity.
  const out = deriveDockedTeamRollups(groups, membership, [], [uni()])
  expect(out.find((r) => r.groupId === 'g1')).toEqual({
    groupId: 'g1',
    name: 'Alpha',
    memberCount: 2,
    dockedCount: 2,
    locationId: 'port-7',
  })
  // g2 has no unified fleet and no per-ship docks → untouched by the branch.
  expect(out.find((r) => r.groupId === 'g2')).toEqual({
    groupId: 'g2',
    name: 'Bravo',
    memberCount: 1,
    dockedCount: 0,
    locationId: null,
  })
})

test('UNIFIED: an in-space fleet (parked at a coordinate) is NOT a dock — no location, no n/n claim', () => {
  const out = deriveDockedTeamRollups(groups, membership, [], [
    uni({ status: 'idle', location_mode: 'space', current_location_id: null, space_x: 10, space_y: 20 }),
  ])
  expect(out.find((r) => r.groupId === 'g1')).toEqual({
    groupId: 'g1',
    name: 'Alpha',
    memberCount: 2,
    dockedCount: 0,
    locationId: null,
  })
})

test('UNIFIED: a moving fleet is not a dock; a present fleet with a null location is not a dock', () => {
  const out = deriveDockedTeamRollups(groups, membership, [], [
    uni({ status: 'moving', location_mode: 'movement', current_location_id: null }),
    uni({ group_id: 'g2', status: 'present', current_location_id: null }),
  ])
  expect(out.every((r) => r.locationId === null && r.dockedCount === 0)).toBe(true)
})

test('UNIFIED: duplicate group fleets → first wins (fleet_ambiguous is the server\'s to reject, never a guessed second dock)', () => {
  const out = deriveDockedTeamRollups(groups, membership, [], [uni(), uni({ current_location_id: 'port-9' })])
  expect(out.find((r) => r.groupId === 'g1')!.locationId).toBe('port-7')
})

test('UNIFIED: an empty group with a unified fleet claims no dock (the n>0 invariant holds)', () => {
  const out = deriveDockedTeamRollups(groups, { s4: { group_id: null } }, [], [uni()])
  expect(out.find((r) => r.groupId === 'g1')).toEqual({
    groupId: 'g1',
    name: 'Alpha',
    memberCount: 0,
    dockedCount: 0,
    locationId: null,
  })
})

test('UNIFIED: the unified dock WINS over stale per-ship rows for the same group (one truth, the fleet\'s)', () => {
  const out = deriveDockedTeamRollups(
    groups,
    membership,
    [{ main_ship_id: 's1', current_location_id: 'port-1' }], // a stale/partial per-ship row
    [uni()],
  )
  expect(out.find((r) => r.groupId === 'g1')).toMatchObject({ dockedCount: 2, locationId: 'port-7' })
})

// FLEET-GO 4a-1 — excludeCombatSortieFleets: a group fleet 'present' at a COMBAT location is the
// hunt's sortie, never a real dock, and must be dropped before the fold (else a mid-hunt group
// badges "docked" and re-arms Send/Hunt). This is the ONE authority both fold sites share.
const combatLocs = [
  { id: 'haven', activity_type: 'none' },
  { id: 'hunt-site', activity_type: 'pirate_hunt' },
]
const uf = (over: Partial<UnifiedGroupFleetLite>): UnifiedGroupFleetLite => ({
  group_id: 'g1', status: 'present', location_mode: 'location',
  current_location_id: 'haven', space_x: null, space_y: null, ...over,
})

test('excludeCombatSortieFleets: drops present-at-combat, keeps present-at-safe', () => {
  const kept = excludeCombatSortieFleets([uf({ current_location_id: 'haven' })], combatLocs)
  expect(kept).toHaveLength(1) // docked at a non-combat port → a real dock, kept
  const dropped = excludeCombatSortieFleets([uf({ current_location_id: 'hunt-site' })], combatLocs)
  expect(dropped).toHaveLength(0) // present at a combat site → the sortie, excluded
})

test('excludeCombatSortieFleets: only present is filtered — moving/idle/space pass regardless', () => {
  const fleets = [
    uf({ status: 'moving', current_location_id: 'hunt-site' }),
    uf({ status: 'returning', current_location_id: 'hunt-site' }),
    uf({ status: 'idle', location_mode: 'space', current_location_id: null }),
  ]
  expect(excludeCombatSortieFleets(fleets, combatLocs)).toHaveLength(3)
})

test('excludeCombatSortieFleets: the mid-hunt group no longer folds as docked at the hunt site', () => {
  // The L1 regression: without the filter, this present-at-hunt-site fleet would badge g1 "docked n/n".
  const filtered = excludeCombatSortieFleets([uf({ current_location_id: 'hunt-site' })], combatLocs)
  const rollups = deriveDockedTeamRollups(
    groups, { s1: { group_id: 'g1' }, s2: { group_id: 'g1' } }, [], filtered,
  )
  expect(rollups.find((r) => r.groupId === 'g1')?.locationId).toBeNull()
})

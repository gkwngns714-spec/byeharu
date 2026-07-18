import { test, expect } from '@playwright/test'
import {
  groupMoveAvailability,
  teamMapSendAction,
  unifiedMapSendAction,
  buildCommandShipGroupGoArgs,
  type GroupGoTarget,
} from '../src/features/command/teamMove'

// TEAMMOVE-1 — pure specs for the docked-team move availability mirror + the map sheet's ONE
// expedition-arm action classifier. No I/O, no clock; fixtures are the TEAMMAP rollup shapes.

const base = {
  gateEnabled: true,
  groupResolved: true,
  memberCount: 2,
  dockedLocationId: 'port-1',
  destinationId: 'port-2',
}

test('happy path: a fully-docked team can move to another location', () => {
  expect(groupMoveAvailability(base)).toEqual({ canMove: true, reason: 'ok' })
})

test('reject order mirrors the server: gate → group → empty → docked-together → already-there', () => {
  expect(groupMoveAvailability({ ...base, gateEnabled: false })).toEqual({
    canMove: false,
    reason: 'gate_dark',
  })
  expect(groupMoveAvailability({ ...base, gateEnabled: false, groupResolved: false })).toEqual({
    canMove: false,
    reason: 'gate_dark', // gate answers FIRST, exactly like the RPC's reject-before-read
  })
  expect(groupMoveAvailability({ ...base, groupResolved: false })).toEqual({
    canMove: false,
    reason: 'group_not_found',
  })
  expect(groupMoveAvailability({ ...base, memberCount: 0 })).toEqual({
    canMove: false,
    reason: 'empty_group',
  })
  expect(groupMoveAvailability({ ...base, dockedLocationId: null })).toEqual({
    canMove: false,
    reason: 'not_docked_together', // the server's member_not_ready arm
  })
  expect(groupMoveAvailability({ ...base, dockedLocationId: 'port-2' })).toEqual({
    canMove: false,
    reason: 'already_there', // client-only refinement (server: member_send_failed round-trip saved)
  })
})

// ── teamMapSendAction — the LEGACY expedition-arm classifier (S5: kept as a module for un-flip
//    insurance; the on-map surface is FleetCommandPanel, whose lit arm uses unifiedMapSendAction) ──

test('fully docked elsewhere → move (the 0190 onward hop)', () => {
  expect(
    teamMapSendAction({ memberCount: 2, dockedCount: 2, dockedLocationId: 'port-1', destinationId: 'port-2' }),
  ).toBe('move')
})

test('fully docked at THIS location → docked_here (muted state, no action)', () => {
  expect(
    teamMapSendAction({ memberCount: 2, dockedCount: 2, dockedLocationId: 'port-2', destinationId: 'port-2' }),
  ).toBe('docked_here')
})

test('partial dock (one member away) → docked_unready, never an enabled Send', () => {
  expect(
    teamMapSendAction({ memberCount: 2, dockedCount: 1, dockedLocationId: null, destinationId: 'port-2' }),
  ).toBe('docked_unready')
})

test('split dock (members at different ports) → docked_unready, never an enabled Send', () => {
  expect(
    teamMapSendAction({ memberCount: 2, dockedCount: 2, dockedLocationId: null, destinationId: 'port-2' }),
  ).toBe('docked_unready')
})

test('no docked member → the original home-team send arm', () => {
  expect(
    teamMapSendAction({ memberCount: 2, dockedCount: 0, dockedLocationId: null, destinationId: 'port-2' }),
  ).toBe('send')
})

test('empty team → the send arm (groupSendAvailability disables it as empty_group downstream)', () => {
  expect(
    teamMapSendAction({ memberCount: 0, dockedCount: 0, dockedLocationId: null, destinationId: 'port-2' }),
  ).toBe('send')
})

test('THE LAW: a team with ANY docked member never classifies as send', () => {
  for (const dockedCount of [1, 2, 3]) {
    for (const dockedLocationId of [null, 'port-1', 'port-2']) {
      const action = teamMapSendAction({ memberCount: 3, dockedCount, dockedLocationId, destinationId: 'port-2' })
      expect(action).not.toBe('send')
    }
  }
})

// ── NO-HOME (0199): the launchFromDock gate. DEFAULT-false above stays byte-identical; lit flips
//    'docked_unready' → 'send' (the widened server send launches each member from its own dock). ──
test('NO-HOME: partial/split dock + launchFromDock lit → send (was docked_unready when dark)', () => {
  // partial dock
  expect(
    teamMapSendAction({ memberCount: 2, dockedCount: 1, dockedLocationId: null, destinationId: 'port-2', launchFromDock: true }),
  ).toBe('send')
  // split dock
  expect(
    teamMapSendAction({ memberCount: 2, dockedCount: 2, dockedLocationId: null, destinationId: 'port-2', launchFromDock: true }),
  ).toBe('send')
})

test('NO-HOME: move + docked_here still win over the lit send (relocate/no-op are more precise)', () => {
  // fully docked ELSEWHERE → still move, even with the flag lit
  expect(
    teamMapSendAction({ memberCount: 2, dockedCount: 2, dockedLocationId: 'port-1', destinationId: 'port-2', launchFromDock: true }),
  ).toBe('move')
  // fully docked at THIS port → still docked_here
  expect(
    teamMapSendAction({ memberCount: 2, dockedCount: 2, dockedLocationId: 'port-2', destinationId: 'port-2', launchFromDock: true }),
  ).toBe('docked_here')
})

test('NO-HOME: launchFromDock lit never changes a no-docked-member team (still send)', () => {
  expect(
    teamMapSendAction({ memberCount: 2, dockedCount: 0, dockedLocationId: null, destinationId: 'port-2', launchFromDock: true }),
  ).toBe('send')
})

// ── FLEET-GO 4a-1 — unifiedMapSendAction: the LIT world's ONE-arm classifier. Coexists with the
//    three-arm classifier above (the dark default) — every spec above stays untouched, which is
//    itself the proof the old world is intact. ──

test('UNIFIED: docked at the destination → docked_here (the sole client-side suppression)', () => {
  expect(unifiedMapSendAction({ dockedLocationId: 'port-2', destinationId: 'port-2' })).toBe('docked_here')
})

test('UNIFIED: everything else is GO — the mover launches from anywhere', () => {
  // docked elsewhere (the dark world's 'move') → go
  expect(unifiedMapSendAction({ dockedLocationId: 'port-1', destinationId: 'port-2' })).toBe('go')
  // no dock at all (home / split / parked in space / mid-flight — no rollup location) → go
  expect(unifiedMapSendAction({ dockedLocationId: null, destinationId: 'port-2' })).toBe('go')
})

test('UNIFIED: the classifier never yields the dark-world arms (no move/send/docked_unready)', () => {
  for (const dockedLocationId of [null, 'port-1', 'port-2']) {
    const arm = unifiedMapSendAction({ dockedLocationId, destinationId: 'port-2' })
    expect(['go', 'docked_here']).toContain(arm)
  }
})

// ── FLEET-GO 4a-1 — buildCommandShipGroupGoArgs: the exclusive target shape (0208's rule). ──

test('GO ARGS: a location target carries ONLY p_group_id + p_location_id — never coordinates', () => {
  const args = buildCommandShipGroupGoArgs('g1', { locationId: 'loc-A' })
  expect(args).toEqual({ p_group_id: 'g1', p_location_id: 'loc-A' })
  expect('p_target_x' in args).toBe(false)
  expect('p_target_y' in args).toBe(false)
})

test('GO ARGS: XOR is enforced by construction — a malformed target carrying BOTH shapes still emits only the location', () => {
  // 0208 rejects invalid_target_shape when coords ride alongside a location; the builder makes that
  // reject unreachable from this client by dropping everything but the location id.
  const malformed = { locationId: 'loc-A', x: 5, y: 9 } as unknown as GroupGoTarget
  expect(buildCommandShipGroupGoArgs('g1', malformed)).toEqual({ p_group_id: 'g1', p_location_id: 'loc-A' })
})

test('GO ARGS: a coordinate target goes RAW — no client-side rounding (0208 rounds server-side)', () => {
  const args = buildCommandShipGroupGoArgs('g1', { x: 3.7, y: -2.2 })
  expect(args).toEqual({ p_group_id: 'g1', p_target_x: 3.7, p_target_y: -2.2 })
  expect('p_location_id' in args).toBe(false)
})

import { test, expect } from '@playwright/test'
import {
  groupMoveAvailability,
  teamMapSendAction,
  unifiedMapSendAction,
  buildCommandShipGroupGoArgs,
  fleetRetreatOutcomeMessage,
  retreatCarriesLoot,
  type GroupGoTarget,
} from '../src/features/command/teamMove'
import { openSpaceDestinationLabel } from '../src/features/map/fleetGoTarget'

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

// ── RETREAT TO ANY DESTINATION (0292, widened 0298) — the combat-time outcomes get their OWN copy. ─

test('RETREAT: the two outcomes each get their own message, naming the fleet and the destination', () => {
  expect(fleetRetreatOutcomeMessage('retreat_started', 'Alpha', 'Haven')).toBe(
    'Alpha is breaking off the fight and heading for Haven.',
  )
  expect(fleetRetreatOutcomeMessage('retreat_destination_updated', 'Alpha', 'Haven')).toBe(
    'Alpha will retreat to Haven instead.',
  )
})

test('RETREAT: the destination is a LABEL, not a port name — open space reads honestly', () => {
  // 0298 removed the port-only restriction, so a retreat can be ordered to bare open space. The copy
  // must never imply a port: it interpolates whatever the caller names the place, and the caller
  // (FleetCommandPanel's go arm) passes openSpaceDestinationLabel() for a tapped point.
  const point = openSpaceDestinationLabel({ x: 1204, y: -377 })
  expect(point).toBe('open space at (1204, -377)')
  expect(fleetRetreatOutcomeMessage('retreat_started', 'Alpha', point)).toBe(
    'Alpha is breaking off the fight and heading for open space at (1204, -377).',
  )
  expect(fleetRetreatOutcomeMessage('retreat_destination_updated', 'Alpha', point)).toBe(
    'Alpha will retreat to open space at (1204, -377) instead.',
  )
  // and no sentence the function can produce says "port".
  for (const outcome of ['retreat_started', 'retreat_destination_updated']) {
    expect(fleetRetreatOutcomeMessage(outcome, 'Alpha', point)).not.toContain('port')
  }
})

test('RETREAT: an ordinary move yields null, so the caller keeps its own "Sent …" summary', () => {
  // The envelope key is absent on a normal leg, and `unknown` by TeamRpcResult's shape — anything
  // that is not one of the two combat-time outcomes must fall through, never produce retreat copy.
  for (const outcome of [undefined, null, '', 'moving', 42, {}]) {
    expect(fleetRetreatOutcomeMessage(outcome, 'Alpha', 'Haven')).toBeNull()
  }
  // …and a non-retreat envelope produces no retreat copy even when it carries a reward bundle.
  expect(fleetRetreatOutcomeMessage('moving', 'Alpha', 'Haven', { metal: 120 })).toBeNull()
})

// ── THE COST OF NAMING A DESTINATION — the server says it in `carried_rewards`; the player is told. ─

test('LOOT: a bundle is "carrying something" only when an entry holds a positive number or a list', () => {
  // The 0040 shape, read generically so a future reward key is covered by the same authority.
  expect(retreatCarriesLoot({ metal: 120 })).toBe(true)
  expect(retreatCarriesLoot({ items: [{ item_id: 'scrap', quantity: 3 }] })).toBe(true)
  expect(retreatCarriesLoot({ metal: 0, items: [], crystal: 4 })).toBe(true)
  // Empty, all-zero, or not a bundle at all → no warning. It must never fire over a fight that
  // earned nothing: the server sends coalesce(total_rewards_json, '{}') on every retreat envelope.
  for (const empty of [undefined, null, {}, { metal: 0 }, { metal: 0, items: [] }, [], 'metal', 7]) {
    expect(retreatCarriesLoot(empty)).toBe(false)
  }
})

test('LOOT: with rewards carried, both retreat outcomes say plainly that they are lost', () => {
  // VERIFIED IN THE SERVER SOURCE (see teamMove.ts): the ordered-destination retreat always mints a
  // 'space' leg, and reward_grant fires ONLY from movement_settle_arrival's 'base' arm (0208:153-154)
  // — so the haul is not delayed, it is gone. The copy therefore says "lost", and it says BASE, the
  // word ActiveCombatPanel already uses; docking at a port does not bank it.
  expect(fleetRetreatOutcomeMessage('retreat_started', 'Alpha', 'Haven', { metal: 120 })).toBe(
    'Alpha is breaking off the fight and heading for Haven.' +
      ' The rewards this fight had earned are lost — they are secured only by a retreat back to base.',
  )
  expect(
    fleetRetreatOutcomeMessage('retreat_destination_updated', 'Alpha', 'Haven', { metal: 120 }),
  ).toBe(
    'Alpha will retreat to Haven instead.' +
      ' The rewards this fight had earned are lost — they are secured only by a retreat back to base.',
  )
  // It stays plain: no raw envelope key, no reason code, and still no claim about a port.
  for (const outcome of ['retreat_started', 'retreat_destination_updated']) {
    const msg = fleetRetreatOutcomeMessage(outcome, 'Alpha', 'Haven', { metal: 120 }) as string
    expect(msg).not.toContain('carried_rewards')
    expect(msg).not.toContain('port')
  }
})

test('LOOT: an empty bundle adds nothing — the retreat copy is byte-identical to the no-argument form', () => {
  for (const outcome of ['retreat_started', 'retreat_destination_updated']) {
    const plain = fleetRetreatOutcomeMessage(outcome, 'Alpha', 'Haven')
    expect(fleetRetreatOutcomeMessage(outcome, 'Alpha', 'Haven', {})).toBe(plain)
    expect(fleetRetreatOutcomeMessage(outcome, 'Alpha', 'Haven', undefined)).toBe(plain)
  }
})

import { test, expect } from '@playwright/test'
import {
  groupMoveAvailability,
  teamMapSendAction,
  unifiedMapSendAction,
  buildCommandShipGroupGoArgs,
  fleetRetreatOutcomeMessage,
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
  // that is not one of the combat-time outcomes must fall through, never produce retreat copy.
  for (const outcome of [undefined, null, '', 'moving', 42, {}]) {
    expect(fleetRetreatOutcomeMessage(outcome, 'Alpha', 'Haven')).toBeNull()
  }
})

// ── REPOSITION (0337): an in-zone order starts a MOVE, and the copy says so in the right tense. ───

test('REPOSITION: the repositioning outcome says the fleet is ON ITS WAY and the fight continues', () => {
  // The owner's rule: "when i am inside the zone and moving(redirecting), it should just move
  // without breaking combat, and battles being continued." 0311 built that as a teleport and the
  // owner met it head-on — "when in combat, and i move, i teleport" — so 0337 made it a real journey
  // the combat tick walks at the fleet's own speed. The copy is present tense BECAUSE OF THAT: the
  // fleet has a course, not an arrival. It must never read as a retreat (nothing broke off) and never
  // as a journey leg (no movement was minted — the fleet is moving inside its own fight).
  const point = openSpaceDestinationLabel({ x: 310, y: 455 })
  expect(fleetRetreatOutcomeMessage('repositioning', 'Alpha', point)).toBe(
    'Alpha is moving to open space at (310, 455) — still in the fight.',
  )
  expect(fleetRetreatOutcomeMessage('repositioning', 'Alpha', 'Haven')).toBe(
    'Alpha is moving to Haven — still in the fight.',
  )
  const msg = fleetRetreatOutcomeMessage('repositioning', 'Alpha', point) as string
  expect(msg).not.toContain('retreat')
  // no jargon, no home/base/win wording (the standing copy laws).
  for (const banned of ['base', 'home', 'win', 'sortie', 'berth']) {
    expect(msg).not.toContain(banned)
  }
})

test('REPOSITION: the retired 0311 token renders NOTHING — the arrival claim cannot come back', () => {
  // 0337 deleted 'repositioned' from the server envelope in the same slice that deleted the teleport
  // from the engine. Mapping it here to a friendly sentence would keep the arrival claim alive on a
  // surface after the behaviour behind it was removed — the exact "documenting a limitation the owner
  // told me to delete" shape. An unknown outcome falls through to null, and the caller keeps its own
  // ordinary-move summary.
  expect(fleetRetreatOutcomeMessage('repositioned', 'Alpha', 'Haven')).toBeNull()
})

// ── LOOT (0307): naming a destination costs nothing — so the copy no longer threatens the player. ──

test('LOOT: the "rewards are lost" warning is GONE from every retreat sentence (0307)', () => {
  // That warning documented the pre-0307 defect (movement_settle_arrival's 'space' arm deposited
  // nothing) as a rule of the game, and it said "back to base" — a place the NO-HOME law deleted.
  // 0307 makes the 'space' arrival deposit the carried bundle (store at the arrival port, or the
  // oldest active store for a bare point), so the retreat copy must never again claim a loss, and
  // must never again name a base or a home.
  for (const outcome of ['retreat_started', 'retreat_destination_updated']) {
    for (const dest of ['Haven', openSpaceDestinationLabel({ x: 1204, y: -377 })]) {
      const msg = fleetRetreatOutcomeMessage(outcome, 'Alpha', dest) as string
      expect(msg).toBeTruthy()
      expect(msg).not.toContain('lost')
      expect(msg).not.toContain('base')
      expect(msg).not.toContain('home')
      expect(msg).not.toContain('carried_rewards')
    }
  }
  // And the deleted fourth parameter stays deleted: the function's copy depends on nothing but the
  // outcome, the fleet name and the destination label.
  expect(fleetRetreatOutcomeMessage.length).toBe(3)
})

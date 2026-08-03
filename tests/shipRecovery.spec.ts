import { test, expect } from '@playwright/test'
import {
  freshestShipStatus,
  recoveryReasonMessage,
  repairGate,
  repairPosition,
  repairPositionLine,
  towReasonMessage,
  towSuccessMessage,
  type DisabledShipRow,
} from '../src/features/ship/shipRecovery'
import { repairReasonMessage } from '../src/features/ship/repairReasonMessage'

// 0297 REPAIR REQUIRES A PORT, unified by 0335 — specs for the pure recovery gate + its copy.
// The rules under test are the ones that make the slice safe:
//   · a disabled ship ALWAYS gets exactly one recovery action offered — never none;
//   · an unavailable readiness read FAILS OPEN (Repair stays offered; the server is the enforcer);
//   · no raw server code ever reaches the screen, and there is now only ONE vocabulary to map.
//
// ONE-SURFACE (this slice): the client no longer carries a SECOND decider beside `repairGate`.
// `repairConcept` — which existed only to choose between two mounted repair blocks — is deleted
// with the second block, and so is the spec that had to assert the two deciders agreed. The gate
// is the one decider, and `repairPosition` folds it (plus the living-hull projection) into the ONE
// position vocabulary the surface renders from.
// Run: `npx playwright test shipRecovery.spec.ts`.

const AT_PORT: DisabledShipRow = { main_ship_id: 's1', name: 'Kestrel', at_port: true, location_id: 'haven' }
const ADRIFT: DisabledShipRow = { main_ship_id: 's2', name: 'Vagrant', at_port: false, location_id: null }

test('freshestShipStatus: the refetched shared read wins; the selection row is the fallback', () => {
  // fresher-read-first — a mid-session destruction lands in the shared read long before the
  // never-repolled selection list hears of it.
  expect(freshestShipStatus({ status: 'destroyed' }, { status: 'stationary' })).toBe('destroyed')
  expect(freshestShipStatus({ status: 'stationary' }, { status: 'destroyed' })).toBe('stationary')
  // pre-load (null) and a missing row (undefined — also the shape of a failed shared read that
  // collapsed to []) fall back to the selection status; the leaf's doc states that limit.
  expect(freshestShipStatus(null, { status: 'home' })).toBe('home')
  expect(freshestShipStatus(undefined, { status: 'destroyed' })).toBe('destroyed')
})

test('a healthy ship has no recovery surface at all', () => {
  const gate = repairGate('home', [AT_PORT], 's1')
  expect(gate.kind).toBe('not_disabled')
})

test('a disabled ship IN PORT is offered Repair, never the tow', () => {
  const gate = repairGate('destroyed', [AT_PORT, ADRIFT], 's1')
  expect(gate).toEqual({ kind: 'at_port', locationId: 'haven' })
  expect(repairPosition(gate, undefined)).toBe('at_port')
})

test('a disabled ship ADRIFT is offered the tow, and Repair is refused with the reason', () => {
  const gate = repairGate('destroyed', [AT_PORT, ADRIFT], 's2')
  expect(gate).toEqual({ kind: 'adrift' })
  expect(repairPosition(gate, undefined)).toBe('away')
  expect(repairPositionLine(true, 'away')).toContain('port')
})

test('EVERY disabled state offers exactly one action — a wreck is never left with none', () => {
  for (const rows of [[AT_PORT, ADRIFT], null, [] as DisabledShipRow[]]) {
    for (const id of ['s1', 's2', 'unknown-ship']) {
      const gate = repairGate('destroyed', rows, id)
      const at = repairPosition(gate, undefined)
      // Exactly one action, never both, never neither: 'away' is the tow, everything else is Repair.
      expect(['at_port', 'away', 'unknown']).toContain(at)
      // And the surface always has a sentence explaining which one, and why.
      expect(repairPositionLine(true, at)).not.toBeNull()
    }
  }
})

test('an unavailable readiness read FAILS OPEN — Repair stays offered (the server is the enforcer)', () => {
  const gate = repairGate('destroyed', null, 's1')
  expect(gate.kind).toBe('unknown')
  // 'unknown' is NOT 'away': the tow never displaces a Repair we cannot rule out.
  expect(repairPosition(gate, undefined)).toBe('unknown')
})

test('a ship missing from a successful read is also unknown, not silently stranded', () => {
  const gate = repairGate('destroyed', [AT_PORT], 'not-in-the-read')
  expect(gate.kind).toBe('unknown')
  expect(repairPosition(gate, undefined)).toBe('unknown')
})

test("the server's not_at_port reject outranks a stale readiness read", () => {
  // The read still claims this wreck is in port, but the repair just came back adrift.
  const gate = repairGate('destroyed', [AT_PORT], 's1', true)
  expect(gate).toEqual({ kind: 'adrift' })
  expect(repairPosition(gate, undefined)).toBe('away')
})

// ── repairPosition — THE ONE position answer, for a wreck and for a dent alike ────────────────────
// Two client projections cover DISJOINT ship sets and neither can answer for the other:
// get_my_fleet_positions EXCLUDES destroyed ships outright (shipRecoveryApi.ts), and
// get_my_disabled_ships contains ONLY destroyed ships. The server asks one question through one
// authority (mainship_port_of_ship — 0335); this fold is the client half of that, so the surface
// reads ONE position value whatever state the hull is in.
test('repairPosition: a WRECK reads its position from the gate, never from the fleet projection', () => {
  // The wreck's fleet-positions row does not exist (the server excludes it), so a fold that only
  // knew about `place` would answer 'unknown' forever and the tow could never appear.
  expect(repairPosition({ kind: 'at_port', locationId: 'haven' }, undefined)).toBe('at_port')
  expect(repairPosition({ kind: 'adrift' }, undefined)).toBe('away')
  expect(repairPosition({ kind: 'unknown' }, undefined)).toBe('unknown')
  // And the gate OUTRANKS a stale/foreign positions row for a wreck — one authority per state.
  expect(repairPosition({ kind: 'adrift' }, { place: 'docked' })).toBe('away')
  expect(repairPosition({ kind: 'at_port', locationId: 'h' }, { place: 'in_space' })).toBe('at_port')
})

test('repairPosition: a LIVING hull reads its position from the fleet-positions row', () => {
  expect(repairPosition({ kind: 'not_disabled' }, { place: 'docked' })).toBe('at_port')
  expect(repairPosition({ kind: 'not_disabled' }, { place: 'berthed' })).toBe('at_port')
  expect(repairPosition({ kind: 'not_disabled' }, { place: 'in_space' })).toBe('away')
  expect(repairPosition({ kind: 'not_disabled' }, { place: 'transit' })).toBe('away')
  expect(repairPosition({ kind: 'not_disabled' }, { place: 'hidden' })).toBe('unknown')
  expect(repairPosition({ kind: 'not_disabled' }, undefined)).toBe('unknown')
})

// ── repairPositionLine — ONE sentence source for the ONE surface ─────────────────────────────────
// Replaces the pair that existed only because there were two blocks: repairGateNote (wreck copy,
// keyed on the gate) and repairDockStateLine (dent copy, keyed on the dock state). One function,
// keyed on the two facts that actually decide the sentence.
test('repairPositionLine: a WRECK always gets a sentence — adrift names the tow, in port names Repair', () => {
  const adrift = repairPositionLine(true, 'away')
  expect(adrift).not.toBeNull()
  expect(adrift!.toLowerCase()).toContain('tow')
  for (const state of ['at_port', 'unknown'] as const) {
    const line = repairPositionLine(true, state)
    expect(line).not.toBeNull()
    expect(line!.toLowerCase()).toContain('repair')
    // NOT the tow sentence: a wreck we can repair is never told to tow it first.
    expect(line).not.toBe(adrift)
  }
})

test('repairPositionLine: a DENT speaks only when it cannot be mended here, in the server’s own words', () => {
  // away → the availability mirror's not_at_port copy VERBATIM (one sentence source: a real server
  // reject shows the same words).
  expect(repairPositionLine(false, 'away')).toBe(repairReasonMessage('not_at_port'))
  // at_port → the mend renders instead; unknown → no position claim is honest. Both say nothing.
  expect(repairPositionLine(false, 'at_port')).toBeNull()
  expect(repairPositionLine(false, 'unknown')).toBeNull()
})

test('repairPositionLine: no raw server code ever reaches the player, in any of the six cells', () => {
  for (const wreck of [true, false]) {
    for (const state of ['at_port', 'away', 'unknown'] as const) {
      const line = repairPositionLine(wreck, state)
      if (line !== null) expect(line).not.toContain('_')
    }
  }
})

// ── recovery copy: ONE vocabulary, ONE override (0335) ───────────────────────────────────────────
// Before 0335 this module owned a whole private reason set, because repair_main_ship RAISED and its
// codes arrived as exception SUBSTRINGS. The verb now returns the same {ok, reason} envelope the
// priced mend always used, so recoveryReasonMessage delegates to the ONE map and overrides exactly
// one key — the one where the generic sentence would be useless advice to a wreck.
test('every 0335 reject reaching a wreck maps to player words — never a raw code', () => {
  const reasons = [
    'not_authenticated',
    'invalid_request',
    'ship_not_found',
    'not_at_port',
    'nothing_to_repair',
    'hull_unrepairable',
  ]
  for (const r of reasons) {
    const msg = recoveryReasonMessage(r)
    expect(msg.length).toBeGreaterThan(0)
    expect(msg).not.toContain('_') // no snake_case code leaks through
  }
})

test('the ONE override: a wreck rejected for position is told to TOW, not to "take it to a port"', () => {
  const wreck = recoveryReasonMessage('not_at_port')
  expect(wreck.toLowerCase()).toContain('tow')
  // deliberately NOT the generic line — a wreck cannot take itself anywhere.
  expect(wreck).not.toBe(repairReasonMessage('not_at_port'))
})

test('every other reason is the SAME sentence the mend shows — one copy source, not two', () => {
  for (const r of ['not_authenticated', 'ship_not_found', 'nothing_to_repair', 'hull_unrepairable']) {
    expect(recoveryReasonMessage(r)).toBe(repairReasonMessage(r))
  }
})

test('an unrecognised failure degrades to the generic line (no throw, no raw text)', () => {
  expect(recoveryReasonMessage('unavailable')).toBe('Repair unavailable.')
  expect(recoveryReasonMessage('totally_unknown_code')).toBe('Repair unavailable.')
})

test('every mainship_emergency_tow reason maps to distinct player words', () => {
  const reasons = ['not_authenticated', 'ship_not_found', 'ship_not_disabled', 'already_at_port', 'no_port_available']
  const seen = new Set<string>()
  for (const r of reasons) {
    const msg = towReasonMessage(r)
    expect(msg.length).toBeGreaterThan(0)
    expect(msg).not.toContain('_')
    seen.add(msg)
  }
  expect(seen.size).toBe(reasons.length)
  // the transport fallback + anything unknown degrade to the generic line
  expect(towReasonMessage('unavailable')).toBe('The tow is unavailable right now. Try again in a moment.')
  expect(towReasonMessage('totally_unknown')).toBe('The tow is unavailable right now. Try again in a moment.')
})

test('the tow success line names the port when the server gave one', () => {
  expect(towSuccessMessage('Haven Reach')).toBe('Towed to Haven Reach. Repair it here.')
  expect(towSuccessMessage(null)).toBe('Towed to port. Repair it here.')
})

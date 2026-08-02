import { test, expect } from '@playwright/test'
import {
  canRepair,
  canTow,
  isAdriftError,
  repairConcept,
  repairErrorMessage,
  repairGate,
  repairGateNote,
  towReasonMessage,
  towSuccessMessage,
  type DisabledShipRow,
} from '../src/features/ship/shipRecovery'

// 0297 REPAIR REQUIRES A PORT — specs for the pure recovery gate + its reason→copy maps.
// The rules under test are the ones that make the slice safe:
//   · a disabled ship ALWAYS gets exactly one recovery action offered — never none;
//   · an unavailable readiness read FAILS OPEN (Repair stays offered; the server is the enforcer);
//   · no raw server code or raise text ever reaches the screen.
// Run: `npx playwright test shipRecovery.spec.ts`.

const AT_PORT: DisabledShipRow = { main_ship_id: 's1', name: 'Kestrel', at_port: true, location_id: 'haven' }
const ADRIFT: DisabledShipRow = { main_ship_id: 's2', name: 'Vagrant', at_port: false, location_id: null }

// ── repairConcept (REPAIR-WHERE-YOU-ARE: the ONE mount decision for the condition block) ─────────
// Both FittingDetail mount sites read this single value (`surface === 'paid_mend'` /
// `surface === 'free_recovery'`) — neither carries its own status comparison. HONESTY NOTE: these
// specs pin the DECIDER; the JSX composition consuming it is not covered by any rendered test
// (no harness mounts FittingDetail today) — stated plainly rather than papered over with a spec
// that could not fail.
test('repairConcept: destroyed → the free recovery block; every live status → the paid mend', () => {
  expect(repairConcept('destroyed')).toBe('free_recovery')
  for (const status of ['home', 'stationary', 'traveling', 'anything_else', '']) {
    expect(repairConcept(status)).toBe('paid_mend')
  }
})

test('repairConcept agrees with the free gate: free_recovery exactly when the gate has a surface', () => {
  // The server's mutual exclusion, held between the two client deciders: the free block renders
  // (gate ≠ not_disabled) exactly when repairConcept routes to it — one concept per state, never
  // both, never neither.
  for (const status of ['destroyed', 'home', 'stationary', 'traveling']) {
    const routesFree = repairConcept(status) === 'free_recovery'
    const gateActive = repairGate(status, null, 's1').kind !== 'not_disabled'
    expect(routesFree).toBe(gateActive)
  }
})

test('a healthy ship has no recovery surface at all', () => {
  const gate = repairGate('home', [AT_PORT], 's1')
  expect(gate.kind).toBe('not_disabled')
  expect(repairGateNote(gate)).toBeNull()
  expect(canRepair(gate)).toBe(false)
  expect(canTow(gate)).toBe(false)
})

test('a disabled ship IN PORT is offered Repair, never the tow', () => {
  const gate = repairGate('destroyed', [AT_PORT, ADRIFT], 's1')
  expect(gate).toEqual({ kind: 'at_port', locationId: 'haven' })
  expect(canRepair(gate)).toBe(true)
  expect(canTow(gate)).toBe(false)
})

test('a disabled ship ADRIFT is offered the tow, and Repair is refused with the reason', () => {
  const gate = repairGate('destroyed', [AT_PORT, ADRIFT], 's2')
  expect(gate).toEqual({ kind: 'adrift' })
  expect(canRepair(gate)).toBe(false)
  expect(canTow(gate)).toBe(true)
  expect(repairGateNote(gate)).toContain('port')
})

test('EVERY disabled state offers exactly one action — a wreck is never left with none', () => {
  for (const rows of [[AT_PORT, ADRIFT], null, [] as DisabledShipRow[]]) {
    for (const id of ['s1', 's2', 'unknown-ship']) {
      const gate = repairGate('destroyed', rows, id)
      expect(canRepair(gate) !== canTow(gate)).toBe(true) // exactly one, never both, never neither
      expect(repairGateNote(gate)).not.toBeNull()
    }
  }
})

test('an unavailable readiness read FAILS OPEN — Repair stays offered (the server is the enforcer)', () => {
  const gate = repairGate('destroyed', null, 's1')
  expect(gate.kind).toBe('unknown')
  expect(canRepair(gate)).toBe(true)
  expect(canTow(gate)).toBe(false)
})

test('a ship missing from a successful read is also unknown, not silently stranded', () => {
  const gate = repairGate('destroyed', [AT_PORT], 'not-in-the-read')
  expect(gate.kind).toBe('unknown')
  expect(canRepair(gate)).toBe(true)
})

test("the server's ship_not_at_port reject outranks a stale readiness read", () => {
  // The read still claims this wreck is in port, but the repair just came back adrift.
  const gate = repairGate('destroyed', [AT_PORT], 's1', true)
  expect(gate).toEqual({ kind: 'adrift' })
  expect(canTow(gate)).toBe(true)
})

test('every repair_main_ship raise maps to player words — never the raw message', () => {
  const raises = [
    'repair_main_ship: ship_not_at_port — this ship is adrift; tow it to a port before repairing',
    'repair_main_ship: ship is not disabled (status home) — nothing to repair',
    'repair_main_ship: no main ship found',
    'repair_main_ship: not authenticated',
    'repair_main_ship: invalid max_hp (0)',
  ]
  const seen = new Set<string>()
  for (const r of raises) {
    const msg = repairErrorMessage(new Error(r))
    expect(msg.length).toBeGreaterThan(0)
    expect(msg).not.toContain('repair_main_ship')
    expect(msg).not.toContain('_') // no snake_case code leaks through
    seen.add(msg)
  }
  expect(seen.size).toBe(raises.length) // each raise has its OWN copy
})

test('an unrecognised failure degrades to the generic line (no throw, no raw text)', () => {
  expect(repairErrorMessage(new Error('TypeError: fetch failed'))).toBe(
    'Repairs are unavailable right now. Try again in a moment.',
  )
  expect(repairErrorMessage(null)).toBe('Repairs are unavailable right now. Try again in a moment.')
  expect(repairErrorMessage(undefined)).toBe('Repairs are unavailable right now. Try again in a moment.')
})

test('only the position reject flips the ship to adrift', () => {
  expect(isAdriftError(new Error('repair_main_ship: ship_not_at_port — …'))).toBe(true)
  expect(isAdriftError(new Error('repair_main_ship: ship is not disabled (status home)'))).toBe(false)
  expect(isAdriftError(null)).toBe(false)
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

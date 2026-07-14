import { test, expect } from '@playwright/test'
import {
  fleetCommandState,
  fleetCapacityState,
  canToggleCommandShip,
  buildShipGroupMap,
  FLEET_MAX_SHIPS,
  type ShipMembershipRow,
} from '../src/features/command/teamRoster'
import { teamReasonMessage } from '../src/features/command/teamReasonMessage'

const base: ShipMembershipRow[] = [
  { main_ship_id: 's1', group_id: 'g1', captain_slots: 6 },
  { main_ship_id: 's2', group_id: 'g1', captain_slots: 6 },
  { main_ship_id: 's3', group_id: null, captain_slots: 6 },
]

// FLEET-CONTROL (0204) — pure-logic specs for the fleet control-model client mirrors. The server
// (migration 0204) is authoritative; these pins protect the DARK-safety of the mirrors (dark → today's
// behavior byte-identical) and the LIT gate arithmetic (a fleet with no command ship is inactive; the
// 8-ship cap).

test('fleetCommandState — DARK: a fleet is NEVER inactive (today’s behavior)', () => {
  // No command ship, but fleet control is dark → active (movement never required a command ship).
  expect(fleetCommandState({ commandCount: 0, fleetControlEnabled: false })).toEqual({
    active: true,
    commandCount: 0,
  })
  expect(fleetCommandState({ commandCount: 2, fleetControlEnabled: false }).active).toBe(true)
})

test('fleetCommandState — LIT: active ⇔ at least one command ship', () => {
  expect(fleetCommandState({ commandCount: 0, fleetControlEnabled: true })).toEqual({
    active: false,
    commandCount: 0,
  })
  expect(fleetCommandState({ commandCount: 1, fleetControlEnabled: true }).active).toBe(true)
  // multiple command ships (backups) is still just active
  expect(fleetCommandState({ commandCount: 3, fleetControlEnabled: true }).active).toBe(true)
})

test('fleetCapacityState — DARK: no cap (remaining null)', () => {
  expect(fleetCapacityState({ memberCount: 8, fleetControlEnabled: false })).toEqual({
    atCap: false,
    remaining: null,
    max: FLEET_MAX_SHIPS,
  })
  expect(fleetCapacityState({ memberCount: 99, fleetControlEnabled: false }).atCap).toBe(false)
})

test('fleetCapacityState — LIT: atCap at 8, remaining counts down, never negative', () => {
  expect(fleetCapacityState({ memberCount: 0, fleetControlEnabled: true })).toEqual({
    atCap: false,
    remaining: 8,
    max: 8,
  })
  expect(fleetCapacityState({ memberCount: 7, fleetControlEnabled: true })).toEqual({
    atCap: false,
    remaining: 1,
    max: 8,
  })
  // the 8th ship is fine; the 9th is what the server rejects fleet_full → atCap at exactly 8.
  expect(fleetCapacityState({ memberCount: 8, fleetControlEnabled: true })).toEqual({
    atCap: true,
    remaining: 0,
    max: 8,
  })
  expect(fleetCapacityState({ memberCount: 12, fleetControlEnabled: true })).toEqual({
    atCap: true,
    remaining: 0,
    max: 8,
  })
})

test('canToggleCommandShip — must be in a fleet to designate; clearing always allowed', () => {
  // designate (true) requires a fleet
  expect(canToggleCommandShip({ shipGroupId: 'g1', isCommand: true })).toBe(true)
  expect(canToggleCommandShip({ shipGroupId: null, isCommand: true })).toBe(false)
  // clearing (false) is always allowed, even ungrouped
  expect(canToggleCommandShip({ shipGroupId: null, isCommand: false })).toBe(true)
  expect(canToggleCommandShip({ shipGroupId: 'g1', isCommand: false })).toBe(true)
})

test('buildShipGroupMap — a FAILED is_command_ship read (null) never drops fleet membership', () => {
  // The deploy-window regression guard (review HIGH): on a pre-0204 DB the command read errors → null.
  // Membership MUST survive intact; every ship simply reads is_command_ship=false.
  const map = buildShipGroupMap(base, null)
  expect(map.s1.group_id).toBe('g1') // membership preserved
  expect(map.s2.group_id).toBe('g1')
  expect(map.s3.group_id).toBe(null)
  expect(map.s1.captain_slots).toBe(6)
  expect(map.s1.is_command_ship).toBe(false)
  expect(map.s2.is_command_ship).toBe(false)
})

test('buildShipGroupMap — the command overlay only sets flags, never touches membership', () => {
  const map = buildShipGroupMap(base, [
    { main_ship_id: 's1', is_command_ship: true },
    { main_ship_id: 's2', is_command_ship: false },
    { main_ship_id: 's3', is_command_ship: null },
    { main_ship_id: 'ghost', is_command_ship: true }, // a command row with no membership row is ignored
  ])
  expect(map.s1).toEqual({ group_id: 'g1', captain_slots: 6, is_command_ship: true })
  expect(map.s2.is_command_ship).toBe(false)
  expect(map.s3.is_command_ship).toBe(false) // null → false
  expect(map.ghost).toBeUndefined() // membership is base-only; the overlay never adds a ship
})

test('teamReasonMessage — the new 0204 rejects map to player copy, unknowns stay generic', () => {
  expect(teamReasonMessage('fleet_inactive_no_command')).toContain('command ship')
  expect(teamReasonMessage('fleet_full')).toContain('8')
  expect(teamReasonMessage('ship_not_in_fleet')).toContain('fleet')
  // unmapped still degrades to the generic fallback (fail-closed, never a raw code)
  expect(teamReasonMessage('some_unknown_reason')).toBe('Fleet order unavailable.')
})

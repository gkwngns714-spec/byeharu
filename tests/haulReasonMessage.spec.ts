import { test, expect } from '@playwright/test'
import { haulReasonMessage } from '../src/features/port/haulReasonMessage'

// HAUL-3 — pure unit proof for the fail-closed haul reason→message map (the tradeReasonMessage
// mold). Every mapped server reason (migrations 0179 accept/deliver + 0181 read) yields specific
// player-facing text; any unmapped/unknown reason (incl. the haulApi transport 'unavailable'
// fallback) hits the generic "Contract unavailable." — never a raw code.
// Run: `npx playwright test haulReasonMessage.spec.ts`.

test('every known server reason maps to specific player text (not the fallback)', () => {
  const known: Record<string, string> = {
    haul_contracts_disabled: 'Contracts are not available here yet.',
    not_authenticated: 'Sign in to take contracts.',
    invalid_request: 'Invalid command request.',
    invalid_location: 'No port selected.',
    ship_not_found: 'No ship available.',
    not_docked: 'Dock at a port to work contracts.',
    contract_not_found: 'That contract is no longer on the board.',
    already_accepted: 'You already hold this contract.',
    already_accepted_other: 'Another hauler already took that contract.',
    too_many_active: 'You are at your active contract limit.',
    wrong_port: 'Deliver at the destination port.',
    deadline_passed: 'The delivery deadline has passed.',
    insufficient_cargo: 'Not enough cargo aboard to deliver.',
  }
  for (const [reason, msg] of Object.entries(known)) {
    expect(haulReasonMessage(reason)).toBe(msg)
    expect(haulReasonMessage(reason)).not.toBe('Contract unavailable.')
  }
})

test('an unmapped/unknown reason (incl. transport fallback) hits the generic fallback', () => {
  expect(haulReasonMessage('some_unknown_reason')).toBe('Contract unavailable.')
  expect(haulReasonMessage('unavailable')).toBe('Contract unavailable.')
  expect(haulReasonMessage('')).toBe('Contract unavailable.')
})

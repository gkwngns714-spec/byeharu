import { test, expect } from '@playwright/test'
import { shipyardReasonMessage } from '../src/features/port/shipyardReasonMessage'

// SHIPYARD-3 — pure unit proof for the fail-closed shipyard reason→message map (the
// salvageReasonMessage/haulReasonMessage mold). Every mapped server code (migration 0188's
// start_hull_build WRAPPER reject vocabulary — the client-visible `code` names, in the RPC's own
// order) yields specific player-facing text; any unmapped/unknown code (incl. the shipyardApi
// transport 'unavailable' fallback and the wrapper's own else-arm 'unavailable') hits the generic
// "Shipyard unavailable." — never a raw code.
// Run: `npx playwright test shipyardReasonMessage.spec.ts`.

test('every known server code maps to specific player text (not the fallback)', () => {
  const known: Record<string, string> = {
    not_authenticated: 'Sign in to order a hull build.',
    feature_disabled: 'The shipyard is not open yet.',
    invalid_request: 'Invalid command request.',
    unknown_hull: 'Unknown hull class.',
    no_recipe: 'This hull cannot be built at a shipyard.',
    hull_prerequisite_not_met: 'You must own the prerequisite hull first.',
    captain_level_too_low: 'A higher-level captain is required.',
    queue_full: 'Your build queue is full.',
    insufficient_items: 'Not enough materials to start this build.',
    insufficient_credits: 'Not enough credits to start this build.',
  }
  for (const [code, msg] of Object.entries(known)) {
    expect(shipyardReasonMessage(code)).toBe(msg)
    expect(shipyardReasonMessage(code)).not.toBe('Shipyard unavailable.')
  }
})

test('an unmapped/unknown code (incl. the transport/wrapper fallback) hits the generic fallback', () => {
  expect(shipyardReasonMessage('some_unknown_code')).toBe('Shipyard unavailable.')
  expect(shipyardReasonMessage('unavailable')).toBe('Shipyard unavailable.')
  expect(shipyardReasonMessage('')).toBe('Shipyard unavailable.')
})

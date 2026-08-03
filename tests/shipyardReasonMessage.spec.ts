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
    not_authenticated: 'Sign in to order a ship build.',
    feature_disabled: 'The shipyard is not open yet.',
    invalid_request: 'Invalid command request.',
    unknown_hull: 'Unknown ship design.',
    no_recipe: 'This ship can’t be built at a shipyard.',
    hull_prerequisite_not_met: 'You must own the required ship first.',
    captain_level_too_low: 'A higher-level captain is required.',
    queue_full: 'Your build queue is full.',
    // 0333 — items live in PORT storage now, so the shortfall is about THIS port's stock, and the
    // three law-3 codes the order path can newly return each get their own specific text.
    insufficient_items: 'Not enough materials stored at this port.',
    insufficient_credits: 'Not enough credits to start this build.',
    not_docked: 'Dock at a port to order from what is stored there.',
    port_has_no_storage: 'This place has no storage.',
    ship_not_found: 'No ship available.',
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

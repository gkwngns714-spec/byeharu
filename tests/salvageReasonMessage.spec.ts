import { test, expect } from '@playwright/test'
import { salvageReasonMessage } from '../src/features/port/salvageReasonMessage'

// SALVAGE-2 — pure unit proof for the fail-closed salvage reason→message map (the
// haulReasonMessage/tradeReasonMessage mold). Every mapped server reason (migration 0174's
// sell_item_at_port reject vocabulary, in the RPC's own order) yields specific player-facing
// text; any unmapped/unknown reason (incl. the salvageApi transport 'unavailable' fallback) hits
// the generic "Sale unavailable." — never a raw code.
// Run: `npx playwright test salvageReasonMessage.spec.ts`.

test('every known server reason maps to specific player text (not the fallback)', () => {
  const known: Record<string, string> = {
    salvage_market_disabled: 'The salvage market is not open here yet.',
    not_authenticated: 'Sign in to sell salvage.',
    invalid_request: 'Invalid command request.',
    invalid_item: 'That item cannot be sold.',
    invalid_quantity: 'Enter a whole quantity of 1 or more.',
    ship_not_found: 'No ship available.',
    not_docked: 'Dock at a port to sell salvage.',
    no_demand: 'This port does not buy that item.',
    insufficient_items: 'Not enough of that item to sell.',
  }
  for (const [reason, msg] of Object.entries(known)) {
    expect(salvageReasonMessage(reason)).toBe(msg)
    expect(salvageReasonMessage(reason)).not.toBe('Sale unavailable.')
  }
})

test('an unmapped/unknown reason (incl. transport fallback) hits the generic fallback', () => {
  expect(salvageReasonMessage('some_unknown_reason')).toBe('Sale unavailable.')
  expect(salvageReasonMessage('unavailable')).toBe('Sale unavailable.')
  expect(salvageReasonMessage('')).toBe('Sale unavailable.')
})

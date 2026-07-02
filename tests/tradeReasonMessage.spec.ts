import { test, expect } from '@playwright/test'
import { tradeReasonMessage } from '../src/features/map/tradeReasonMessage'

// TRADE-UI-1 — pure unit proof for the fail-closed trade reason→message map. Every mapped server reason
// (migrations 0087/0089/0090) yields specific player-facing text; any unmapped/unknown reason (incl. the
// tradeApi transport 'unavailable' fallback) hits the generic "Trade unavailable." — never a raw code.
// Run: `npx playwright test tradeReasonMessage.spec.ts`.

test('every known server reason maps to specific player text (not the fallback)', () => {
  const known: Record<string, string> = {
    trade_market_disabled: 'Trading is not available here yet.',
    not_docked: 'Dock at a station to trade.',
    not_authenticated: 'Sign in to trade.',
    no_ship: 'No ship selected.',
    offer_unavailable: "This good isn't traded here.",
    insufficient_credits: 'Not enough credits.',
    insufficient_volume: 'Not enough cargo space.',
    insufficient_cargo: 'Not enough cargo to sell.',
    invalid_qty: 'Enter a whole quantity of 1 or more.',
  }
  for (const [reason, msg] of Object.entries(known)) {
    expect(tradeReasonMessage(reason)).toBe(msg)
    expect(tradeReasonMessage(reason)).not.toBe('Trade unavailable.')
  }
})

test('an unmapped/unknown reason (incl. transport fallback) hits the generic fallback', () => {
  expect(tradeReasonMessage('some_unknown_reason')).toBe('Trade unavailable.')
  expect(tradeReasonMessage('unavailable')).toBe('Trade unavailable.')
  expect(tradeReasonMessage('')).toBe('Trade unavailable.')
})

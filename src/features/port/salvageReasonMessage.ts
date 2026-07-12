// SALVAGE-2 — pure, fail-closed reason→message map for the salvage-market surface
// (sell_item_at_port). Maps the ACTUAL server reason strings (migration 0174's full reject
// vocabulary) to short player-facing text; any unmapped/unknown reason — INCLUDING the salvageApi
// transport fallback 'unavailable', which is deliberately NOT in the map — degrades to the
// generic "Sale unavailable." so the UI never surfaces a raw code and never throws. No React/DOM/state — unit-testable directly, the
// haulReasonMessage.ts / tradeReasonMessage.ts mold. The salvageMarket.ts availability mirror
// reuses these exact reason names, so display-only prechecks and real server rejects share ONE
// copy source.

const REASON_MESSAGES: Record<string, string> = {
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

/** A short player-facing message for a server/transport salvage reason; unknown → generic "Sale unavailable." */
export function salvageReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Sale unavailable.'
}

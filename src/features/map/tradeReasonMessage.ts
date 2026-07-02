// TRADE-UI-1 — pure, fail-closed reason→message map for the trade surface (get_market_offers / market_buy /
// market_sell). Maps the ACTUAL server reason strings (migrations 0087/0089/0090) plus the tradeApi transport
// fallback ('unavailable') to short player-facing text; any unmapped/unknown reason degrades to a generic
// "Trade unavailable." so the UI never surfaces a raw code and never throws. No React/DOM/state — unit-testable
// directly, mirroring mainshipStatusLabel.ts's pure-helper pattern.

const REASON_MESSAGES: Record<string, string> = {
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

/** A short player-facing message for a server/transport trade reason; unknown → generic "Trade unavailable." */
export function tradeReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Trade unavailable.'
}

// REPAIR-ECON — pure, fail-closed reason→message map for the paid hull-repair surface
// (repair_ship_hull_at_port). Maps the ACTUAL server reason strings (migration 0201's full reject
// vocabulary) to short player-facing text; any unmapped/unknown reason — INCLUDING the repairApi
// transport fallback 'unavailable', deliberately NOT in the map — degrades to the generic "Repair
// unavailable." so the UI never surfaces a raw code and never throws. No React/DOM/state —
// unit-testable directly, the salvageReasonMessage.ts / haulReasonMessage.ts mold. The repairEconomy.ts
// availability mirror reuses these exact reason names, so display-only prechecks and real server
// rejects share ONE copy source.

const REASON_MESSAGES: Record<string, string> = {
  repair_economy_disabled: 'Repairs are not available here yet.',
  not_authenticated: 'Sign in to repair.',
  invalid_request: 'Invalid command request.',
  invalid_amount: 'Enter a whole amount of hull to repair (1 or more).',
  ship_not_found: 'No ship available.',
  // The safelock seam: a destroyed ship recovers through the FREE recovery path, not the paid desk.
  ship_destroyed: 'This ship is disabled — recover it first (free), then it can be repaired.',
  not_docked: 'Dock at a port to repair the hull.',
  nothing_to_repair: 'Hull is already at full integrity.',
  repair_misconfigured: 'Repair pricing is unavailable right now.',
  insufficient_credits: 'Not enough credits for that repair.',
}

/** A short player-facing message for a server/transport repair reason; unknown → generic "Repair unavailable." */
export function repairReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Repair unavailable.'
}

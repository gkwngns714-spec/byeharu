// SHIPYARD-3 — pure, fail-closed reason→message map for the shipyard order surface
// (start_hull_build). Maps the ACTUAL server code strings (migration 0188's full wrapper reject
// vocabulary — the wrapper keys its rejects on `code`, the writer's internal `reason` names never
// leave it) to short player-facing text; any unmapped/unknown code — INCLUDING the shipyardApi
// transport fallback 'unavailable', which is deliberately NOT in the map — degrades to the
// generic "Shipyard unavailable." so the UI never surfaces a raw code and never throws. No
// React/DOM/state — unit-testable directly, the salvageReasonMessage.ts / haulReasonMessage.ts
// mold. The shipyard.ts availability mirror reuses these exact code names, so display-only
// prechecks and real server rejects share ONE copy source.

const REASON_MESSAGES: Record<string, string> = {
  feature_disabled: 'The shipyard is not open yet.',
  not_authenticated: 'Sign in to order a hull build.',
  invalid_request: 'Invalid command request.',
  unknown_hull: 'Unknown hull class.',
  no_recipe: 'This hull cannot be built at a shipyard.',
  hull_prerequisite_not_met: 'You must own the prerequisite hull first.',
  captain_level_too_low: 'A higher-level captain is required.',
  queue_full: 'Your build queue is full.',
  insufficient_items: 'Not enough materials to start this build.',
  insufficient_credits: 'Not enough credits to start this build.',
}

/** A short player-facing message for a server/transport shipyard code; unknown → generic
 *  "Shipyard unavailable." */
export function shipyardReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Shipyard unavailable.'
}

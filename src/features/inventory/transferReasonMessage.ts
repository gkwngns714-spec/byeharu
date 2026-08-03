// ITEMS-HAVE-A-PLACE (0332) — pure, fail-closed reason→message map for the hold↔storage transfer
// (transfer_items). Maps the ACTUAL server reason strings (0332's full reject vocabulary) to short
// player-facing text; any unmapped reason — INCLUDING the holdApi transport fallback 'unavailable',
// deliberately NOT in the map — degrades to a generic line, so the UI never surfaces a raw code and
// never throws. No React/DOM/state (the salvageReasonMessage.ts mold).
//
// PLAIN WORDS, per the shipped vocabulary (Shop / Sell Items / Inventory / Storage): the ship side
// is "hold", the port side is "storage". No jargon, no server codes, no apologising for a
// limitation the design deleted.

const REASON_MESSAGES: Record<string, string> = {
  not_authenticated: 'Sign in to move items.',
  station_storage_disabled: 'Port storage is not open yet.',
  invalid_request: 'Invalid command request.',
  invalid_direction: 'Pick which way to move the items.',
  invalid_item: 'That item cannot be moved.',
  invalid_quantity: 'Enter a whole quantity of 1 or more.',
  ship_not_found: 'No ship available.',
  // Law 3, in the player's words: storage is reachable only from the port it belongs to.
  not_docked: 'Dock at the port to reach its storage.',
  port_has_no_storage: 'This place has no storage.',
  insufficient_items: "You aren't carrying that many.",
  insufficient_stored: "This port doesn't have that many stored.",
  hold_over_capacity: "That won't fit in your hold.",
}

/** A short player-facing message for a server/transport transfer reason; unknown → generic. */
export function transferReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Move unavailable.'
}

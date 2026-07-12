// HAUL-3 — pure, fail-closed reason→message map for the haul bulletin surface (get_port_contracts /
// haul_accept_contract / haul_deliver_contract). Maps the ACTUAL server reason strings (migrations
// 0179 + 0181) plus the haulApi transport fallback ('unavailable') to short player-facing text; any
// unmapped/unknown reason degrades to a generic "Contract unavailable." so the UI never surfaces a
// raw code and never throws. No React/DOM/state — unit-testable directly, the tradeReasonMessage.ts
// mold. The haulBoard.ts availability mirrors reuse these exact reason names, so display-only
// prechecks and real server rejects share ONE copy source.

const REASON_MESSAGES: Record<string, string> = {
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

/** A short player-facing message for a server/transport haul reason; unknown → generic "Contract unavailable." */
export function haulReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Contract unavailable.'
}

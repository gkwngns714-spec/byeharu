// ONE WAY TO REPAIR (0335) — THE pure, fail-closed reason→message map for repair.
//
// One server verb (repair_ship_hull) means one reason vocabulary and one copy source. Before 0335
// there were two: this map for the paid mend's envelope, and a second set of branches in
// shipRecovery.ts that matched SUBSTRINGS of repair_main_ship's exception text. That second mapper
// is deleted; every repair outcome — wreck recovery or paid mend — arrives here as a reason key.
//
// Any unmapped/unknown reason — INCLUDING the repairApi transport fallback 'unavailable',
// deliberately NOT in the map — degrades to the generic "Repair unavailable." so the UI never
// surfaces a raw code and never throws. No React/DOM/state — unit-testable directly, the
// salvageReasonMessage.ts / haulReasonMessage.ts mold. The repairEconomy.ts availability mirror
// reuses these exact reason names, so display-only prechecks and real server rejects share ONE copy
// source; the sentence that describes the ship's POSITION SITUATION (rather than a server reject)
// lives in shipRecovery.repairPositionLine, which composes this map for the one case where the two
// coincide — a living hull that is not at a port reads not_at_port's words verbatim.

const REASON_MESSAGES: Record<string, string> = {
  repair_economy_disabled: 'Repairs are not available here yet.',
  not_authenticated: 'Sign in to repair.',
  invalid_request: 'Invalid command request.',
  invalid_amount: 'Enter a whole amount of hull to repair (1 or more).',
  ship_not_found: 'No ship available.',
  // ONE position reason for one position authority: 0335 merged the paid mend's `not_docked` and
  // the recovery's `ship_not_at_port` — they always asked the same question and only disagreed
  // because they asked two different resolvers.
  not_at_port: 'Take this ship to a port to repair it.',
  nothing_to_repair: 'Hull is already at full integrity.',
  hull_unrepairable: "This ship's hull record is broken — it cannot be repaired.",
  repair_misconfigured: 'Repair pricing is unavailable right now.',
  insufficient_credits: 'Not enough credits for that repair.',
}

/** A short player-facing message for a server/transport repair reason; unknown → generic "Repair unavailable." */
export function repairReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Repair unavailable.'
}

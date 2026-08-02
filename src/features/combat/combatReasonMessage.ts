// THE ONE reject-copy map for the two combat-time verbs a player can race — pure and fail-closed,
// the teamReasonMessage idiom verbatim (a Record + a total function; unknown input degrades to a
// generic sentence, never a raw code, never a throw). No React/DOM/state — unit-tested in
// tests/combatReasonMessage.spec.ts.
//
// WHY THIS EXISTS (0307's client half): both verbs used to surface RAW POSTGRES TEXT to the player.
// A double-pressed Retreat rendered `request_retreat: presence not active (is retreating)`
// (combatApi.ts throws error.message; ActiveCombatPanel rendered it verbatim), and a raced Flee
// rendered the bare token `no_pending` (telegraphApi.ts throws res.reason; TelegraphBanner rendered
// it). Both vocabularies below are enumerated FROM THE SERVER SOURCE, not guessed.
//
// TWO MAPS, NOT ONE, AND NOT FOLDED INTO teamReasonMessage: these are different wire contracts.
// request_retreat (20260616000019:80) RAISES, so what arrives is a raise MESSAGE (one of them
// parameterized with the presence status — location_presence's domain is
// active/retreating/leaving/completed/destroyed/expired, 20260616000008:21). combat_flee_pending
// (20260618000230:146) returns {ok:false, reason} envelopes, so what arrives is a bare TOKEN.
// teamReasonMessage maps the fleet-RPC reject vocabulary with its own "Fleet order unavailable."
// fallback — wrong copy for a combat surface — so these live beside it, same shape, own fallbacks.

// ── Retreat (request_retreat, 20260616000019:93-103 — the full raise vocabulary) ─────────────────
const RETREAT_MESSAGES: Record<string, string> = {
  'request_retreat: not authenticated': 'Sign in to command your fleet.',
  'request_retreat: presence not found': 'This fight is already over.',
  'request_retreat: not owned': 'That fleet isn’t yours to command.',
}

/** Player copy for a failed Retreat press. `raw` is the thrown message (the server raise text, or
 *  transport noise) — anything unrecognized degrades to the generic retry sentence. */
export function retreatErrorMessage(raw: string): string {
  const exact = RETREAT_MESSAGES[raw]
  if (exact) return exact
  // The parameterized raise: `request_retreat: presence not active (is <status>)`. A presence
  // already retreating/leaving means the FIRST press worked — the double-press is a no-op, and the
  // copy says so instead of alarming. Any terminal status means the fight ended under the player.
  if (raw.startsWith('request_retreat: presence not active')) {
    return raw.includes('(is retreating)') || raw.includes('(is leaving)')
      ? 'Your fleet is already retreating.'
      : 'This fight is already over.'
  }
  return 'Couldn’t order the retreat — try again.'
}

// ── Flee (combat_flee_pending, 20260618000230 — the full ok:false reason vocabulary) ─────────────
// `presence_already_closed` is NOT here on purpose: it rides an ok:true envelope (0230:190-192), so
// telegraphApi never throws it. `flee_failed` is telegraphApi's own fallback token for an ok:false
// envelope that carried no reason.
const FLEE_MESSAGES: Record<string, string> = {
  // The resolver won the race — combat opened before the flee landed (0230:179-181). The banner
  // unmounts on the next poll and the combat panel takes over, where Retreat is the door.
  no_pending: 'Too late to slip away — the fight is starting. Order a retreat instead.',
  telegraph_disabled: 'Fleeing isn’t possible right now.',
  not_authenticated: 'Sign in to command your fleet.',
}

/** Player copy for a failed Flee press. `raw` is the thrown message (a reason token, or transport
 *  noise) — anything unrecognized degrades to the generic retry sentence. */
export function fleeErrorMessage(raw: string): string {
  return FLEE_MESSAGES[raw] ?? 'Couldn’t flee — try again.'
}

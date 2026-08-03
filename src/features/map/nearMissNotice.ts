// THE NEAR MISS — "you slipped past them", the event that used to be silence.
//
// ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────────────────
// Owner, 2026-08-03: "i went to snare, zone, no fighting happens." Their last two crossings of the
// Snare were rolled for — risk 0.545 vs roll 0.697, and risk 0.240 vs roll 0.336 — and both MISSED.
// The game said nothing. From the player's chair, "the dice came up in your favour" and "the combat
// system is broken" produce the identical experience: an uneventful trip.
//
// The owner has since decided the probabilistic ambush STAYS (the designed formula, responsive to
// fleet strength and crossing length, over the old 98% certainty). That decision is what makes this
// module load-bearing rather than polish: a 98% system can afford silence on the 2%; a coin flip
// cannot. A near miss has to be a game EVENT — tense — instead of an absence.
//
// ── THE THREE RULES THIS MODULE ENFORCES ─────────────────────────────────────────────────────────
// 1. NEVER for a leg that had no roll. Satisfied by construction, not by a filter here: the
//    deployed `pirate_intercept_plan_leg` inserts a row ONLY for a zone the leg actually crosses,
//    so "no crossing" produces no row for this module to see. (See pirateApi.fetchInterceptMisses.)
// 2. NO RAW NUMBERS. The risk and the roll are on the row and are deliberately not read here. "You
//    slipped past" is the event; "risk 0.545, roll 0.697" is a debug readout, and printing a
//    probability invites the player to argue with the dice instead of feeling them.
// 3. NOT WHILE THE FLEET IS STILL FLYING. The roll is sealed at ORDER time — `plan_leg` runs inside
//    `command_ship_group_go` — so a row exists seconds before the fleet reaches the zone. Announcing
//    it then would narrate a crossing that has not happened. So a miss is announceable only once its
//    leg is no longer among the active movements the shell already polls: the trip is over, and this
//    is what happened on it.
//
//    KNOWN, ACCEPTED EDGE: a leg STOPPED before it reached the zone also leaves the active list, so
//    its miss announces too. The roll genuinely happened and genuinely missed, so the sentence is
//    not false; distinguishing "turned back early" would need the settled movement row, which no
//    client read returns. Documented rather than hidden, and deliberately worded to survive it.
//
// Pure — no React/DOM/fetch, and the clock is an ARGUMENT (the ambushEncounterNotice/zoneInfoModel
// convention), so the specs pin the windowing without faking time.

import type { InterceptMissLite } from './pirateApi'

/** The structural slice of a map location this decision needs (MapLocation satisfies it). */
export interface NearMissLocationLite {
  id: string
  name: string
}

export interface NearMissNotice {
  /** The intercept row id — a stable React key, and never shown to a player. */
  id: string
  text: string
}

/**
 * How long a near miss stays on the MAP. It is news, not a log: the map's clean-by-default law means
 * an alert that never expires becomes furniture. The Mission screen keeps the record without a
 * window (see NEAR_MISS_KEEP_ALL), so nothing is lost by letting the map one fade.
 */
export const NEAR_MISS_MAP_WINDOW_MS = 10 * 60 * 1000

/** Pass as `withinMs` for the "what happened" record, which does not expire. */
export const NEAR_MISS_KEEP_ALL = Number.POSITIVE_INFINITY

/**
 * The ONE sentence. Plain words, no jargon, no codes, no numbers (the map-UX rules + rule 2 above).
 *
 * Past tense and trip-scoped on purpose: it is a fact about a journey that is over, which is the
 * only moment this is ever shown, and it stays true for the stopped-early edge above.
 */
export function nearMissText(placeName: string | null): string {
  return placeName
    ? `Slipped past the pirates around ${placeName}.`
    : 'Slipped past the pirates in a raided zone.'
}

/**
 * The near misses that are worth telling the player about right now, newest first.
 *
 * FAIL CLOSED, ALWAYS: an unparseable timestamp, a still-flying leg, or a row older than the window
 * yields nothing. A missing fact must never become a claim — the worst outcome here is silence,
 * which is merely today's behaviour, and the second worst is telling a player they dodged an ambush
 * on a trip that is still under way.
 *
 * A row whose `location_id` names nothing this client has loaded still gets a notice, using the
 * nameless wording: the EVENT is the news, and suppressing it over an unresolvable name would put us
 * back in silence for exactly the unreleased/RLS-hidden sites where a player is most confused.
 */
export function nearMissNotices(input: {
  misses: readonly InterceptMissLite[]
  locations: readonly NearMissLocationLite[]
  /** ids of the legs still in flight — the shell's already-polled `game.movements`. */
  activeMovementIds: readonly string[]
  nowMs: number
  /** NEAR_MISS_MAP_WINDOW_MS on the map; NEAR_MISS_KEEP_ALL for the record. */
  withinMs: number
  /** Cap on how many are announced at once (the map must not stack a wall of alerts). */
  limit?: number
}): NearMissNotice[] {
  const active = new Set(input.activeMovementIds)
  const out: NearMissNotice[] = []
  for (const m of input.misses) {
    // Rule 3: the leg is still under way — the crossing has not happened yet.
    if (m.movement_id !== null && active.has(m.movement_id)) continue
    const at = Date.parse(m.created_at)
    if (!Number.isFinite(at)) continue
    // A row stamped in the future (clock skew) is not aged out by `now - at`, so bound both sides.
    const age = input.nowMs - at
    if (age < 0 || age > input.withinMs) continue
    const name = m.location_id ? (input.locations.find((l) => l.id === m.location_id)?.name ?? null) : null
    out.push({ id: m.id, text: nearMissText(name) })
  }
  // The read already orders newest-first; sorting here would be a second ordering authority.
  return typeof input.limit === 'number' ? out.slice(0, Math.max(0, input.limit)) : out
}

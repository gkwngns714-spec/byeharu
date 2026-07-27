// INTERCEPT DEFERRED ENTRY — the ambush the player actually experiences, read from ENCOUNTER STATE.
//
// ── WHY NOT FROM THE ORDER RESPONSE ────────────────────────────────────────────────────────────────
// Under the deferred-entry contract the ambush fires LONG AFTER the order returns — the movement
// processor springs it when the fleet reaches the zone entry point. By then the RPC envelope is
// ancient history and the panel that sent the order may not even be mounted. The only thing that can
// tell the player "you were ambushed" is the live encounter, which the app ALREADY polls: useCombat
// (src/features/combat/useCombat.ts) fetches combat_encounters every ~1.5s into the shell state, and
// CombatMapCard renders that same array on the map. This module adds NO fetch, NO poll and NO
// "did we get ambushed" flag — it is a pure function of rows that are already in hand.
//
// ── HOW AN AMBUSH IS TOLD APART FROM A DELIBERATE HUNT ─────────────────────────────────────────────
// Migration 0293 made encounter POSITION separate from encounter IDENTITY and named the rule in
// combat_create_group_encounter's own comment: the engagement point is
//   "p_engagement_x/p_engagement_y when supplied (an INTERCEPT passes the ambush point), otherwise
//    the linked location's centre (an ordinary hunt)."
// So an encounter whose engagement point is NOT its location's centre is one the fleet was dragged
// into on the way somewhere — the ambush. A hunt sits exactly on the centre it sailed to. The
// intercept then restates the ambush point on the row it created (0293 hunk [A2]), so both halves
// agree. This module mirrors that server rule and derives nothing of its own.
//
// FAIL CLOSED, ALWAYS. Anything that leaves the comparison unprovable — no engagement point, a
// non-finite coordinate, no location_id, a location the map has not loaded — yields NO notice. A
// missing fact must never become a claim; the worst outcome here is silence, and the second worst is
// telling a player they were ambushed when they simply arrived and started the fight they chose.
//
// Pure — no React/DOM/fetch/clock. Proven in tests/ambushEncounterNotice.spec.ts.

/** The ONE player-facing sentence. Plain language, no jargon, no codes (the map-UX rules). */
export const AMBUSH_NOTICE_TEXT = 'Ambushed at the zone boundary.'

/** The structural slice of a combat_encounters row this decision needs (CombatEncounter satisfies it). */
export interface AmbushEncounterLite {
  id: string
  status: string
  location_id: string | null
  /** 0293's engagement anchor. Absent when read from a server that predates the column. */
  engagement_x?: number | null
  engagement_y?: number | null
}

/** The structural slice of a map location this decision needs (MapLocation satisfies it). */
export interface AmbushLocationLite {
  id: string
  x: number
  y: number
}

export interface AmbushNotice {
  encounterId: string
  text: string
}

// A fight is LIVE in exactly the two states CombatMapCard already treats as live — a retreating fleet
// is still being shot at. Reusing the same pair keeps the notice and the card in step by definition.
const LIVE_STATUSES = new Set(['active', 'retreating'])

// Both coordinates originate as the SAME stored doubles (the intercept stamps locations-derived or
// path-derived values; a hunt copies locations.x/y verbatim) and cross the wire as JSON numbers, so
// equality is genuinely exact. The epsilon exists only to absorb JSON round-tripping, never to make a
// nearby ambush read as a hunt: a real ambush point sits at the zone boundary, world units away.
const SAME_POINT_EPSILON = 1e-6

const isFinite_ = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/**
 * The live encounters that the fleet was AMBUSHED into, in the order given.
 *
 * One notice per qualifying encounter, keyed by encounter id so a caller can render it beside that
 * encounter's own readout. Returns an empty array whenever nothing qualifies — the clean-map default.
 */
export function ambushEncounterNotices(input: {
  encounters: readonly AmbushEncounterLite[]
  locations: readonly AmbushLocationLite[]
}): AmbushNotice[] {
  const notices: AmbushNotice[] = []
  for (const e of input.encounters) {
    if (!LIVE_STATUSES.has(e.status)) continue
    // No engagement anchor → the server cannot tell us where this fight is. Say nothing.
    if (!isFinite_(e.engagement_x) || !isFinite_(e.engagement_y)) continue
    // No linked location → nothing to compare the anchor against. Say nothing. (0293's standalone
    // drawn-zone ambush creates no encounter at all, so this is not the ambush case going silent.)
    if (e.location_id === null) continue
    const loc = input.locations.find((l) => l.id === e.location_id)
    if (!loc || !isFinite_(loc.x) || !isFinite_(loc.y)) continue
    const offCentre =
      Math.abs(e.engagement_x - loc.x) > SAME_POINT_EPSILON ||
      Math.abs(e.engagement_y - loc.y) > SAME_POINT_EPSILON
    if (offCentre) notices.push({ encounterId: e.id, text: AMBUSH_NOTICE_TEXT })
  }
  return notices
}

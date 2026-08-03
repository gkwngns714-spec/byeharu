// THE STANDING COURSE, MADE VISIBLE — the ONE derivation of "is this fleet moving inside its fight,
// and how far has it got?"
//
// ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────────────────
// Migration 0311 let a fleet redirect INSIDE the danger zone it is fighting in without breaking
// combat, and made that redirect INSTANT — its own header said so. Migration 0316 then cut every
// weapon range by five, which destroyed the measurement the instantness had been justified with, and
// the owner met the result head-on: "when in combat, and i move, i teleport."
//
// 0337 deleted the jump. `command_ship_group_go` now only RECORDS a destination on the encounter
// (`reposition_x/reposition_y`), and the combat tick walks the fleet there at the fleet's own speed —
// min(move_speed) over its living hulls — firing and being fired upon the whole way, arriving after
// several ticks and consuming the order.
//
// That change is invisible unless the client says so. A player who orders a move and sees the marker
// creep two units per tick, with no statement anywhere that a course is being run, is looking at what
// reads exactly like a stuck fleet. This module is the statement.
//
// ── THE FLEET IS THE ACTOR ─────────────────────────────────────────────────────────────────────────
// The owner, on seeing one marker per ship: "why are there four ships? because i have 4 ships in
// fleet? no, show only fleet. it is as a whole." So this reads ONE course for ONE fleet off the
// ENCOUNTER row — the row that is per-fleet by construction — and never per combat unit. There is one
// destination, one remaining distance and one arrival, whatever the hull count underneath.
//
// ── FAIL CLOSED ────────────────────────────────────────────────────────────────────────────────────
// combatApi reads `select('*')`, so a server that predates 0337 simply omits both columns. Absent,
// NULL, or non-finite in EITHER coordinate → `null`, i.e. "no course", which renders nothing. The
// same law the anchor leaf states: a missing column is never a licence to guess. The anchor is read
// the same way, so a fight whose anchor is unusable also yields null rather than a NaN distance that
// would print as "NaN units to go".
//
// PURE. No React, no fetch, no clock. It states what the row already says.

/** The encounter fields a course is read from — structural, so a fixture satisfies it without
 *  passing a whole row. */
export interface RepositionCourseInput {
  status: string
  engagement_x?: number | null
  engagement_y?: number | null
  reposition_x?: number | null
  reposition_y?: number | null
}

export interface RepositionCourseView {
  /** the ordered point, verbatim from the row */
  destination: { x: number; y: number }
  /** where the fleet is now — the anchor the tick moves one step at a time */
  from: { x: number; y: number }
  /** straight-line world units still to run. 0 is possible for one poll (the order is consumed by
   *  the tick that lands, so a client can observe the arrival before the NULL). */
  remaining: number
  /** the one sentence every surface prints. Present tense on purpose: the fleet is ON ITS WAY. */
  text: string
}

/** The only statuses a course can be run under. A RETREATING fight keeps its recorded destination on
 *  the row — 0337 deliberately clears nothing, because the tick's own `status = 'active'` re-read
 *  makes the value unreachable — so the client must apply the SAME rule rather than reporting a
 *  course the engine has already stopped honouring. This constant is that rule, stated once. */
export const COURSE_RUNNING_STATUSES = ['active'] as const

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/**
 * The fleet's standing course, or `null` when it has none.
 *
 * `null` covers every reason at once, and they are all the same answer to the player: no course is
 * being run. No course recorded; a column the server does not have; a fight that is retreating or
 * over; an anchor too broken to measure from.
 */
export function resolveRepositionCourse(
  encounter: RepositionCourseInput | null | undefined,
): RepositionCourseView | null {
  if (!encounter) return null
  if (!(COURSE_RUNNING_STATUSES as readonly string[]).includes(encounter.status)) return null

  const dx = encounter.reposition_x
  const dy = encounter.reposition_y
  const ax = encounter.engagement_x
  const ay = encounter.engagement_y
  if (!finite(dx) || !finite(dy) || !finite(ax) || !finite(ay)) return null

  const remaining = Math.hypot(dx - ax, dy - ay)
  return {
    destination: { x: dx, y: dy },
    from: { x: ax, y: ay },
    remaining,
    // The same "(x, y)" shape the map's own destination label uses, rounded for display only — the
    // row keeps the raw values. It says MOVING, never MOVED: the arrival has not happened yet, and a
    // sentence that claimed it would be the teleport re-appearing in the copy after the engine
    // stopped doing it.
    text: `Moving to (${Math.round(dx)}, ${Math.round(dy)}) — ${Math.round(remaining)} units to go. The fight moves with the fleet.`,
  }
}

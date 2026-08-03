// TEAMMAP-2 — the ONE movement-interpolation helper, EXTRACTED from resolveMainShipMarker (§C/§F
// carried this exact math inline twice; teamMarkers.ts is a third consumer, so the idiom is now
// shared instead of duplicated — the anti-spaghetti reuse law). Pure display math ONLY: it renders
// the server-committed movement segment at a point in time; it derives NO ETA/arrival truth (the
// server's settle owns arrival). Any missing/invalid input → null (never a guessed position).
//
// ── GENERALISED (slice-combat-that-flows): ONE authority, TWO shapes of caller ────────────────────
// Combat needed the identical question — "where is this thing between two known points at time t" —
// for units that step every server tick and for a shell in flight between two hulls. Those inputs
// are millisecond CLOCK READINGS (when the client first observed a row), not the ISO timestamps a
// committed `fleet_movements` row carries, so the ISO signature could not serve them without either
// stringifying a client clock into a fake server timestamp or writing a second lerp somewhere else.
// A second lerp is the spaghetti this module exists to prevent, so the LERP ITSELF was lifted out:
//
//   • `segmentProgress` / `interpolateSegment` — the primitive, over plain millisecond bounds.
//   • `movementProgress` / `interpolateMovementPoint` — thin ISO adapters that PARSE and delegate.
//     Fleet travel is repointed at the generalised form; its behaviour is unchanged, including its
//     stricter fail-closed rule (see below).
//   • map/combatMotion.ts composes the primitive for combat units and for ordnance in flight.
//
// The one deliberate difference between the two layers: a fleet-movement row with `arrive_at <=
// depart_at` is INCOHERENT and still yields null (that guard predates this change and is what stops
// a malformed row drawing a path). The primitive instead accepts `endMs === startMs` as a segment
// that is simply OVER — progress 1, the end point — because combat needs exactly that to express "a
// unit that has just appeared is AT its position and is not being tweened from anywhere".

export interface MovementSegment {
  origin_x: number
  origin_y: number
  target_x: number
  target_y: number
  depart_at: string
  arrive_at: string
}

/** Two known points and the millisecond window between them — the generalised form of a
 *  MovementSegment, with the timestamps already resolved to clock readings. `endMs === startMs` is
 *  legal and means the segment is complete (see the header). */
export interface TimedSegment {
  fromX: number
  fromY: number
  toX: number
  toY: number
  startMs: number
  endMs: number
}

const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)

/**
 * THE PRIMITIVE: how far along `seg` are we at `nowMs`, clamped to [0,1]. Null on any non-finite
 * input or a reversed window (`endMs < startMs`) — never a guessed fraction.
 *
 * CLAMPED, WHICH IS THE WHOLE SAFETY PROPERTY: before `startMs` it is 0 and after `endMs` it is 1,
 * so a caller can never be handed a point OUTSIDE the two known ends. Nothing here extrapolates;
 * a segment whose time is up reports its end point forever, which is what makes a unit that has
 * stopped stay stopped instead of drifting on past its last observed position.
 */
export function segmentProgress(seg: TimedSegment, nowMs: number): number | null {
  if (!finite(seg.startMs) || !finite(seg.endMs) || !finite(nowMs)) return null
  if (seg.endMs < seg.startMs) return null
  if (seg.endMs === seg.startMs) return 1 // a zero-length window is a segment already finished
  return Math.max(0, Math.min(1, (nowMs - seg.startMs) / (seg.endMs - seg.startMs)))
}

/** THE PRIMITIVE: the point on `seg` at `nowMs`. Null when the window or either end is unusable. */
export function interpolateSegment(seg: TimedSegment, nowMs: number): { x: number; y: number } | null {
  const t = segmentProgress(seg, nowMs)
  if (t === null) return null
  if (!finite(seg.fromX) || !finite(seg.fromY) || !finite(seg.toX) || !finite(seg.toY)) return null
  return {
    x: seg.fromX + t * (seg.toX - seg.fromX),
    y: seg.fromY + t * (seg.toY - seg.fromY),
  }
}

/** The ISO movement row as a TimedSegment, or null when its timestamps are missing/incoherent.
 *  `arrive_at <= depart_at` is rejected here (not in the primitive) — see the header. */
function movementSegment(seg: MovementSegment): TimedSegment | null {
  const dep = Date.parse(seg.depart_at)
  const arr = Date.parse(seg.arrive_at)
  if (!finite(dep) || !finite(arr) || arr <= dep) return null
  return {
    fromX: seg.origin_x,
    fromY: seg.origin_y,
    toX: seg.target_x,
    toY: seg.target_y,
    startMs: dep,
    endMs: arr,
  }
}

/**
 * Is this committed segment still IN FLIGHT at `nowMs` — i.e. should its path still be drawn?
 *
 * This is NOT an arrival claim, and it does not settle anything: the server owns arrival. It answers a
 * narrower, display-only question. A due row keeps `status='moving'` until `process_fleet_movements`
 * (the 30s cron) settles it, so for up to ~30s after `arrive_at` the client is handed a movement that is
 * over. Drawing it leaves a stale ghost path from a trip already finished — with no ETA beside it, since
 * `formatCountdown` already returns null once the time passes. Past `arrive_at` the honest answer to
 * "is there an outbound path to draw?" is no.
 *
 * Fails CLOSED on malformed/missing timestamps (false — draw nothing), matching this module's law that a
 * bad input yields no render rather than a guessed one.
 */
export function isMovementInFlight(seg: MovementSegment, nowMs: number): boolean {
  const dep = Date.parse(seg.depart_at)
  const arr = Date.parse(seg.arrive_at)
  if (!finite(dep) || !finite(arr) || arr <= dep) return false
  return nowMs < arr
}

/** Clamped linear interpolation of a committed movement segment at `nowMs` (WORLD coordinates).
 *  An ADAPTER over `interpolateSegment` since slice-combat-that-flows — same math, same
 *  fail-closed contract, one lerp in the codebase. */
export function interpolateMovementPoint(seg: MovementSegment, nowMs: number): { x: number; y: number } | null {
  const timed = movementSegment(seg)
  return timed === null ? null : interpolateSegment(timed, nowMs)
}

// COMMAND-FLEET-STATE — the SAME clamped [0,1] fraction interpolateMovementPoint uses internally,
// exposed directly for a progress bar/percent display (the Command roster's per-fleet meter). Not a
// second interpolation formula — this is the identical `t` that already drives the map's dot position;
// a caller that only needs "how far along" reads this instead of computing {x,y} and discarding it.
// Same fail-closed contract: a malformed or zero-duration segment → null (never a guessed fraction).
export function movementProgress(seg: MovementSegment, nowMs: number): number | null {
  const timed = movementSegment(seg)
  return timed === null ? null : segmentProgress(timed, nowMs)
}

// TEAMMAP-2 — the ONE movement-interpolation helper, EXTRACTED from resolveMainShipMarker (§C/§F
// carried this exact math inline twice; teamMarkers.ts is a third consumer, so the idiom is now
// shared instead of duplicated — the anti-spaghetti reuse law). Pure display math ONLY: it renders
// the server-committed movement segment at a point in time; it derives NO ETA/arrival truth (the
// server's settle owns arrival). Any missing/invalid input → null (never a guessed position).

export interface MovementSegment {
  origin_x: number
  origin_y: number
  target_x: number
  target_y: number
  depart_at: string
  arrive_at: string
}

const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)

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

/** Clamped linear interpolation of a committed movement segment at `nowMs` (WORLD coordinates). */
export function interpolateMovementPoint(seg: MovementSegment, nowMs: number): { x: number; y: number } | null {
  const dep = Date.parse(seg.depart_at)
  const arr = Date.parse(seg.arrive_at)
  if (!finite(dep) || !finite(arr) || arr <= dep) return null
  if (!finite(seg.origin_x) || !finite(seg.origin_y) || !finite(seg.target_x) || !finite(seg.target_y)) return null
  const t = Math.max(0, Math.min(1, (nowMs - dep) / (arr - dep)))
  return {
    x: seg.origin_x + t * (seg.target_x - seg.origin_x),
    y: seg.origin_y + t * (seg.target_y - seg.origin_y),
  }
}

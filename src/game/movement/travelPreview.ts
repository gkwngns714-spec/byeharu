// Client-side travel PREVIEW math only. This mirrors the server's movement_create
// formula so the UI can show an estimated ETA before dispatch. It is NEVER the
// source of truth — once a fleet is sent, the UI renders the server-returned
// arrive_at / status, not this estimate.

export const DEFAULT_TRAVEL_SCALE = 1.0
export const DEFAULT_MIN_TRAVEL_SECONDS = 5

export function distance(ax: number, ay: number, bx: number, by: number): number {
  return Math.hypot(bx - ax, by - ay)
}

/** Slowest unit speed governs the fleet (matches fleet_speed() on the server). */
export function slowestSpeed(selected: Array<{ speed: number; quantity: number }>): number {
  const active = selected.filter((s) => s.quantity > 0 && s.speed > 0)
  if (active.length === 0) return 0
  return Math.min(...active.map((s) => s.speed))
}

export function previewTravelSeconds(
  dist: number,
  fleetSpeed: number,
  scale: number = DEFAULT_TRAVEL_SCALE,
  minSeconds: number = DEFAULT_MIN_TRAVEL_SECONDS,
): number {
  if (!fleetSpeed || fleetSpeed <= 0) return 0
  return Math.max(minSeconds, (dist / fleetSpeed) * scale)
}

/**
 * "m:ss" while time remains; null once the clock reaches zero or there's no
 * target. Callers decide the wording (e.g. "arriving in {clock}" vs an
 * "awaiting server confirmation" state), so we never compose a stray fallback.
 */
export function countdownClock(
  targetIso: string | null | undefined,
  now: number = Date.now(),
): string | null {
  if (!targetIso) return null
  const ms = new Date(targetIso).getTime() - now
  if (ms <= 0) return null
  const total = Math.ceil(ms / 1000)
  const m = Math.floor(total / 60)
  const s = total % 60
  return `${m}:${s.toString().padStart(2, '0')}`
}

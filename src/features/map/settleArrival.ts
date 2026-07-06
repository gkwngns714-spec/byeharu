// UX-CLEANUP item 6 (part A) — PURE, framework-free logic for the on-demand OSN arrival settle.
//
// No React/DOM/fetch here. This module owns: (1) the RPC name literal, (2) a strict fail-closed parser of
// the server envelope, and (3) the due-trigger timing decision (when the client should fire the settle).
// The server (command_main_ship_settle_arrival, migration 0150) is the sole authority: it re-validates the
// flag, ownership, coherence, and due-ness under the SAME locks the arrival cron uses and settles via the
// cron's own primitives — a stale or early client call is a clean {settled:false} no-op, never a mutation.

export const SETTLE_ARRIVAL_RPC = 'command_main_ship_settle_arrival' as const
// Item 6 part B (0151): the LEGACY-family sibling — settles the caller's due fleet_movements arrival
// (MainShipCommand trips + return legs) via the cron's extracted movement_settle_arrival helper.
export const LEGACY_SETTLE_ARRIVAL_RPC = 'command_main_ship_settle_arrival_legacy' as const

// The server's result envelope, mapped fail-closed (anything unrecognized → a safe non-settled error).
// Outcomes: docked/terminal/arrived = OSN (0150); present/completed/failed = legacy (0151).
export type SettleArrivalResult =
  | { ok: true; settled: true; outcome: 'docked' | 'terminal' | 'arrived' | 'present' | 'completed' | 'failed' }
  | { ok: true; settled: false; reason: 'busy' | 'not_due' | 'no_active_movement' | 'already_settled' }
  | { ok: false; reason: string }

const SETTLED_OUTCOMES = ['docked', 'terminal', 'arrived', 'present', 'completed', 'failed'] as const

export function parseSettleArrivalResult(raw: unknown): SettleArrivalResult {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { ok: false, reason: 'malformed' }
  const o = raw as Record<string, unknown>
  if (o.ok === true && o.settled === true) {
    const outcome = o.outcome
    if (typeof outcome === 'string' && (SETTLED_OUTCOMES as readonly string[]).includes(outcome)) {
      return { ok: true, settled: true, outcome: outcome as (typeof SETTLED_OUTCOMES)[number] }
    }
    return { ok: false, reason: 'malformed' }
  }
  if (o.ok === true && o.settled === false) {
    const reason = o.reason
    if (reason === 'busy' || reason === 'not_due' || reason === 'no_active_movement' || reason === 'already_settled') {
      return { ok: true, settled: false, reason }
    }
    return { ok: false, reason: 'malformed' }
  }
  if (o.ok === false && typeof o.reason === 'string' && o.reason.length > 0) {
    return { ok: false, reason: o.reason }
  }
  return { ok: false, reason: 'malformed' }
}

/**
 * Due-trigger timing: how long (ms) until the client should fire the settle for the given movement —
 * 0 when already due, a positive delay when the arrival is in the future, or null when there is nothing
 * to schedule (no movement / not moving / unparseable arrive_at — fail closed: the cron remains the
 * backstop either way, so a null here can never strand a ship).
 */
export function computeSettleDelayMs(
  movement: { status: string; arrive_at: string } | null | undefined,
  nowMs: number,
): number | null {
  if (!movement || movement.status !== 'moving') return null
  const t = Date.parse(movement.arrive_at)
  if (!Number.isFinite(t)) return null
  return Math.max(0, t - nowMs)
}

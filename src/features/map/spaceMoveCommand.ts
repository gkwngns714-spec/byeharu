// OSN-3 S6C origin, 4A-POST trimmed — PURE, framework-free map-gesture + coordinate-grid helpers.
//
// No React/DOM/SVG/fetch here. The per-ship coordinate command surface (RPC shape, error copy, and
// the stateful submit controller) was deleted with the per-ship movement client; what remains are
// the two LIVE pieces the fleet mover reuses:
//   1. the canonical integer-grid rounding that mirrors the server's round(numeric) — the fleet
//      coordinate-go PREVIEW + same-point comparison (fleetGoTarget.ts);
//   2. the pointer-gesture classifier (tap vs pan, multi-touch never targets) — GalaxyMap's
//      open-space tap ownership.

import type { WorldCoord } from './openSpaceTransform'

// Canonical integer world-unit grid, matching the server wrappers' `round(numeric)` = half-AWAY-from-zero
// (round(0.5)=1, round(-0.5)=-1, round(2.5)=3, round(-2.5)=-3). JS `Math.round` is half-toward-+Inf, so
// round the magnitude and re-apply the sign. UI preview only — the server re-canonicalizes and is
// authoritative; non-finite stays non-finite (callers reject via isWithinOpenSpaceBounds).
export function roundHalfAwayFromZero(n: number): number {
  if (!Number.isFinite(n)) return NaN
  return Math.sign(n) * Math.round(Math.abs(n))
}
export function canonicalizeWorldTarget(w: WorldCoord): WorldCoord {
  return { x: roundHalfAwayFromZero(w.x), y: roundHalfAwayFromZero(w.y) }
}

// ── Gesture ownership ────────────────────────────────────────────────────────────────────────────────
// A single, short, near-stationary pointer is a target tap; everything else stays map pan/zoom.
// Multi-touch is NEVER a target. Thresholds per the S6C charter (~8px travel, <400ms).
export const TAP_MAX_TRAVEL_PX = 8
export const TAP_MAX_DURATION_MS = 400

export interface PointerGestureSample {
  travelPx: number // total pointer displacement down→up, CSS px
  durationMs: number // down→up duration, ms
  maxPointers: number // peak simultaneous active pointers during the gesture
}
export type PointerGesture = 'tap' | 'pan'

export function classifyPointerGesture(s: PointerGestureSample): PointerGesture {
  if (s.maxPointers > 1) return 'pan' // multi-touch never selects a target
  if (!Number.isFinite(s.travelPx) || !Number.isFinite(s.durationMs)) return 'pan'
  if (s.travelPx > TAP_MAX_TRAVEL_PX) return 'pan'
  if (s.durationMs > TAP_MAX_DURATION_MS) return 'pan'
  return 'tap'
}

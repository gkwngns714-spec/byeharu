import { test, expect } from '@playwright/test'
import {
  roundHalfAwayFromZero,
  canonicalizeWorldTarget,
  classifyPointerGesture,
  TAP_MAX_TRAVEL_PX,
  TAP_MAX_DURATION_MS,
} from '../src/features/map/spaceMoveCommand'

// OSN-3 S6C origin, 4A-POST trimmed — pure proofs for the LIVE map-gesture + coordinate-grid helpers.
// The per-ship command surface (RPC shape / error copy / controller) was deleted with the per-ship
// movement client; the survivors are reused by the fleet coordinate-go (fleetGoTarget.ts) and
// GalaxyMap's tap ownership. No browser/page, no DB, no network. Run: `npm run verify:osn:s6c`.

// ── Canonical integer-grid rounding (must mirror the server: round = half-AWAY-from-zero) ─────────────
test('roundHalfAwayFromZero matches Postgres round(numeric)', () => {
  expect(roundHalfAwayFromZero(0.5)).toBe(1)
  expect(roundHalfAwayFromZero(-0.5)).toBe(-1)
  expect(roundHalfAwayFromZero(2.5)).toBe(3)
  expect(roundHalfAwayFromZero(-2.5)).toBe(-3)
  expect(roundHalfAwayFromZero(2.4)).toBe(2)
  expect(roundHalfAwayFromZero(-2.6)).toBe(-3)
  expect(roundHalfAwayFromZero(0)).toBe(0)
  expect(Number.isNaN(roundHalfAwayFromZero(NaN))).toBe(true)
  expect(Number.isNaN(roundHalfAwayFromZero(Infinity))).toBe(true)
})

test('canonicalizeWorldTarget rounds both axes to the integer grid', () => {
  expect(canonicalizeWorldTarget({ x: 1234.5, y: -6789.5 })).toEqual({ x: 1235, y: -6790 })
  expect(canonicalizeWorldTarget({ x: -0.5, y: 0.49 })).toEqual({ x: -1, y: 0 })
})

// ── Gesture ownership: tap vs pan; multi-touch never targets ──────────────────────────────────────────
test('classifyPointerGesture: short stationary single tap → tap', () => {
  expect(classifyPointerGesture({ travelPx: 0, durationMs: 50, maxPointers: 1 })).toBe('tap')
  expect(classifyPointerGesture({ travelPx: TAP_MAX_TRAVEL_PX, durationMs: TAP_MAX_DURATION_MS, maxPointers: 1 })).toBe('tap')
})

test('classifyPointerGesture: drag beyond travel threshold → pan', () => {
  expect(classifyPointerGesture({ travelPx: TAP_MAX_TRAVEL_PX + 0.01, durationMs: 50, maxPointers: 1 })).toBe('pan')
})

test('classifyPointerGesture: long press beyond duration threshold → pan', () => {
  expect(classifyPointerGesture({ travelPx: 1, durationMs: TAP_MAX_DURATION_MS + 1, maxPointers: 1 })).toBe('pan')
})

test('classifyPointerGesture: multi-touch is NEVER a tap', () => {
  expect(classifyPointerGesture({ travelPx: 0, durationMs: 10, maxPointers: 2 })).toBe('pan')
})

test('classifyPointerGesture: non-finite samples → pan (no accidental selection)', () => {
  expect(classifyPointerGesture({ travelPx: NaN, durationMs: 10, maxPointers: 1 })).toBe('pan')
  expect(classifyPointerGesture({ travelPx: 1, durationMs: NaN, maxPointers: 1 })).toBe('pan')
})

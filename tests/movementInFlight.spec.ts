import { test, expect } from '@playwright/test'
import { isMovementInFlight, type MovementSegment } from '../src/features/map/movementInterpolation'

// FLEET-READ — pure unit proof for the in-flight path predicate. No browser/page.
//
// Why it exists: the map is handed rows already filtered to status='moving', but that status is settled by
// the 30s `process_fleet_movements` cron, so a finished trip keeps its row for up to ~30s and left a stale
// path drawn across the map from a journey already over. This predicate is the display-only answer to
// "should the outbound path still be drawn?" — it settles nothing and claims no arrival.
// Run: `npx playwright test movementInFlight.spec.ts`.

const DEP = '2026-01-01T00:00:00Z'
const ARR = '2026-01-01T00:10:00Z'
const depMs = Date.parse(DEP)
const arrMs = Date.parse(ARR)

const seg = (over: Partial<MovementSegment> = {}): MovementSegment => ({
  origin_x: 0,
  origin_y: 0,
  target_x: 100,
  target_y: 100,
  depart_at: DEP,
  arrive_at: ARR,
  ...over,
})

test('mid-flight → drawn', () => {
  expect(isMovementInFlight(seg(), depMs + (arrMs - depMs) / 2)).toBe(true)
})

test('at departure → drawn (the whole trip is ahead)', () => {
  expect(isMovementInFlight(seg(), depMs)).toBe(true)
})

test('one ms before arrival → still drawn', () => {
  expect(isMovementInFlight(seg(), arrMs - 1)).toBe(true)
})

test('EXACTLY at arrive_at → gone (the trip is over; the countdown has expired too)', () => {
  expect(isMovementInFlight(seg(), arrMs)).toBe(false)
})

test('after arrival → gone — the ghost path this fix removes', () => {
  expect(isMovementInFlight(seg(), arrMs + 1)).toBe(false)
})

test('the ~30s settle window: due but still status=moving → NOT drawn', () => {
  // The exact case the user hit: the cron has not yet flipped the row, so the client still holds it.
  expect(isMovementInFlight(seg(), arrMs + 29_000)).toBe(false)
})

test('before depart_at (a clock skew / scheduled trip) → drawn, not hidden', () => {
  expect(isMovementInFlight(seg(), depMs - 5_000)).toBe(true)
})

// Fail closed — matches the module's law that a bad input renders nothing rather than a guess.
test('malformed timestamps → not drawn', () => {
  expect(isMovementInFlight(seg({ arrive_at: 'nonsense' }), depMs)).toBe(false)
  expect(isMovementInFlight(seg({ depart_at: '' }), depMs)).toBe(false)
})

test('arrive_at <= depart_at (a degenerate segment) → not drawn', () => {
  expect(isMovementInFlight(seg({ arrive_at: DEP }), depMs - 1)).toBe(false)
  expect(isMovementInFlight(seg({ arrive_at: '2025-12-31T23:59:00Z' }), depMs - 1)).toBe(false)
})

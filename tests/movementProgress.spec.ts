import { test, expect } from '@playwright/test'
import { movementProgress, type MovementSegment } from '../src/features/map/movementInterpolation'

// COMMAND-FLEET-STATE — pure unit proof for movementProgress, the SAME clamped [0,1] fraction
// interpolateMovementPoint computes internally, exposed directly for the Command roster's per-fleet
// progress bar. No browser/page. Run: `npx playwright test movementProgress.spec.ts`.

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

test('at departure → 0', () => {
  expect(movementProgress(seg(), depMs)).toBe(0)
})

test('midpoint → 0.5', () => {
  expect(movementProgress(seg(), depMs + (arrMs - depMs) / 2)).toBe(0.5)
})

test('at arrival → 1', () => {
  expect(movementProgress(seg(), arrMs)).toBe(1)
})

test('before departure → clamped to 0, never negative', () => {
  expect(movementProgress(seg(), depMs - 5_000)).toBe(0)
})

test('after arrival → clamped to 1, never over', () => {
  expect(movementProgress(seg(), arrMs + 29_000)).toBe(1)
})

// Fail closed — matches the module's law that a bad/degenerate input yields null, never a guessed fraction.
test('malformed timestamps → null', () => {
  expect(movementProgress(seg({ arrive_at: 'nonsense' }), depMs)).toBeNull()
  expect(movementProgress(seg({ depart_at: '' }), depMs)).toBeNull()
})

test('arrive_at <= depart_at (a degenerate segment) → null', () => {
  expect(movementProgress(seg({ arrive_at: DEP }), depMs)).toBeNull()
  expect(movementProgress(seg({ arrive_at: '2025-12-31T23:59:00Z' }), depMs)).toBeNull()
})

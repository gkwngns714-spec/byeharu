import { test, expect } from '@playwright/test'
import { meterPairSrLabel, shipMeterPair } from '../src/features/ship/meterPair'

// SHIELD-2 — pure-logic specs for the ONE shield/hull meter-pair view-model shared by
// ShipStatusCard and ShipDossier (no app/Supabase). Pins the data-gate (max_shield <= 0 → the
// shield reading is null → zero shield DOM — every prod ship today), the partial/full readings,
// BOTH clamps (a bar must never overflow or run negative even on malformed input), the fail-closed
// non-finite handling, and the sr-only pair label contract.
// Run: `npx playwright test shipMeterPair.spec.ts`.

// ── the data gate: shieldless ships derive NO shield reading ─────────────────────────────────────

test('zero max_shield hides the shield reading (the prod-today shape)', () => {
  const pair = shipMeterPair({ shield: 0, max_shield: 0, hp: 90, max_hp: 100 })
  expect(pair.shield).toBeNull()
  expect(pair.hull).toEqual({ current: 90, max: 100, pct: 90 })
})

test('missing/undefined shield columns fail closed to hidden (older cached bundle racing the column add)', () => {
  const pair = shipMeterPair({ hp: 50, max_hp: 100 })
  expect(pair.shield).toBeNull()
  expect(pair.hull.pct).toBe(50)
})

test('negative max_shield (malformed) hides rather than renders a broken bar', () => {
  expect(shipMeterPair({ shield: 5, max_shield: -1, hp: 1, max_hp: 1 }).shield).toBeNull()
})

test('non-finite values fail closed (NaN max hides; NaN current reads 0)', () => {
  expect(shipMeterPair({ shield: 3, max_shield: NaN, hp: 1, max_hp: 1 }).shield).toBeNull()
  const pair = shipMeterPair({ shield: NaN, max_shield: 40, hp: 1, max_hp: 1 })
  expect(pair.shield).toEqual({ current: 0, max: 40, pct: 0 })
})

// ── partial + full readings ──────────────────────────────────────────────────────────────────────

test('partial shield: exact pct', () => {
  const pair = shipMeterPair({ shield: 3, max_shield: 40, hp: 100, max_hp: 100 })
  expect(pair.shield).toEqual({ current: 3, max: 40, pct: 7.5 })
  expect(pair.hull.pct).toBe(100)
})

test('full shield: pct 100 exactly', () => {
  expect(shipMeterPair({ shield: 40, max_shield: 40, hp: 1, max_hp: 1 }).shield?.pct).toBe(100)
})

// ── clamping (a server clamp breach must never break the bar) ────────────────────────────────────

test('over-max clamps to 100, negative clamps to 0 (shield and hull alike)', () => {
  const over = shipMeterPair({ shield: 50, max_shield: 40, hp: 120, max_hp: 100 })
  expect(over.shield?.pct).toBe(100)
  expect(over.hull.pct).toBe(100)
  const under = shipMeterPair({ shield: -5, max_shield: 40, hp: -10, max_hp: 100 })
  expect(under.shield?.pct).toBe(0)
  expect(under.hull.pct).toBe(0)
})

test('zero max_hp reads hull pct 0 (the pre-existing ShipStatusCard guard, preserved)', () => {
  expect(shipMeterPair({ shield: 0, max_shield: 0, hp: 5, max_hp: 0 }).hull.pct).toBe(0)
})

// ── the sr-only pair label ───────────────────────────────────────────────────────────────────────

test('sr label speaks the pair only when the shield row shows', () => {
  const shown = shipMeterPair({ shield: 3, max_shield: 40, hp: 90, max_hp: 100 })
  expect(meterPairSrLabel(shown)).toBe('Shield 3/40 · Hull 90/100')
  const hidden = shipMeterPair({ shield: 0, max_shield: 0, hp: 90, max_hp: 100 })
  expect(meterPairSrLabel(hidden)).toBeNull()
})

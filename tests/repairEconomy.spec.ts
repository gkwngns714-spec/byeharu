import { test, expect } from '@playwright/test'
import {
  clampRepairHp,
  foldRepairRate,
  isDestroyed,
  missingHull,
  repairAvailability,
  repairBlocks,
  repairConfigFromRows,
  repairCostFor,
  type ShipHull,
} from '../src/features/port/repairEconomy'

// REPAIR-ECON — pure-logic specs for the paid hull-repair client mirrors (no app/Supabase). Asserts the
// same reject ORDER as the server RPC repair_ship_hull_at_port (migration 0201): gate FIRST, then amount
// validation (integer hp — never rounded), then ship, then the DESTROYED safelock seam, then docking,
// then something-to-repair, then affordability — plus the hull math, the whole-hp clamp, the cost math,
// the strict config fold, and the positive-rate knob fold. Run: `npx playwright test repairEconomy.spec.ts`.

const hull = (over: Partial<ShipHull> = {}): ShipHull => ({ hp: 380, maxHp: 500, status: 'stationary', ...over })

// A fully-repairable input; tests flip one clause at a time (the salvageMarket mold).
const repairOk = () => ({
  flagOn: true,
  amount: 120,
  shipResolved: true,
  destroyed: false,
  docked: true,
  missing: 120,
  affordable: true as boolean | null,
})

// ── config fold ────────────────────────────────────────────────────────────────────────────────────
test('repairConfigFromRows: only jsonb true lights; the knob + starting-credits fold', () => {
  expect(
    repairConfigFromRows([
      { key: 'repair_economy_enabled', value: true },
      { key: 'repair_credits_per_hp', value: 0.5 },
      { key: 'starting_credits', value: 250 },
    ]),
  ).toEqual({ enabled: true, creditsPerHp: 0.5, startingCredits: 250 })
})

test('repairConfigFromRows: the STRING "true" reads DARK (strict fold — the server-parity guarantee)', () => {
  const cfg = repairConfigFromRows([{ key: 'repair_economy_enabled', value: 'true' }])
  expect(cfg.enabled).toBe(false)
})

test('repairConfigFromRows: absent flag / empty rows read DARK', () => {
  expect(repairConfigFromRows([]).enabled).toBe(false)
  expect(repairConfigFromRows([{ key: 'repair_credits_per_hp', value: 0.5 }]).enabled).toBe(false)
})

test('foldRepairRate: positive numbers/strings fold; junk/zero/negative → null (a rate must be > 0)', () => {
  expect(foldRepairRate(0.5)).toBe(0.5)
  expect(foldRepairRate('2')).toBe(2)
  expect(foldRepairRate(0)).toBeNull()
  expect(foldRepairRate(-1)).toBeNull()
  expect(foldRepairRate('')).toBeNull()
  expect(foldRepairRate(null)).toBeNull()
  expect(foldRepairRate('abc')).toBeNull()
})

// ── hull math ──────────────────────────────────────────────────────────────────────────────────────
test('isDestroyed: only status=destroyed is the free-safelock subject', () => {
  expect(isDestroyed(hull({ status: 'destroyed', hp: 0 }))).toBe(true)
  expect(isDestroyed(hull({ status: 'stationary' }))).toBe(false)
})

test('missingHull: max_hp − hp, never negative, floored', () => {
  expect(missingHull(hull({ hp: 380, maxHp: 500 }))).toBe(120)
  expect(missingHull(hull({ hp: 500, maxHp: 500 }))).toBe(0)
  expect(missingHull(hull({ hp: 600, maxHp: 500 }))).toBe(0) // over-full never negative
})

test('clampRepairHp: whole 1..missing; fractional floors; over-request caps at missing', () => {
  expect(clampRepairHp(40, 120)).toBe(40)
  expect(clampRepairHp(2.9, 120)).toBe(2)
  expect(clampRepairHp(0, 120)).toBe(1)
  expect(clampRepairHp(9999, 120)).toBe(120) // over-request clamps to missing (server clamps too)
  expect(clampRepairHp(NaN, 120)).toBe(1)
})

test('repairCostFor: hp × rate; unknown rate or non-positive hp → null', () => {
  expect(repairCostFor(120, 0.5)).toBe(60)
  expect(repairCostFor(40, 0.5)).toBe(20)
  expect(repairCostFor(120, null)).toBeNull()
  expect(repairCostFor(0, 0.5)).toBeNull()
})

// ── availability mirror (the 0201 reject order) ──────────────────────────────────────────────────────
test('repairAvailability: everything satisfied → ok', () => {
  expect(repairAvailability(repairOk())).toEqual({ canRepair: true, reason: 'ok' })
})

test('repairAvailability: dark gate wins over EVERYTHING (server order: gate first, before any read)', () => {
  expect(
    repairAvailability({ ...repairOk(), flagOn: false, amount: 0, shipResolved: false, destroyed: true, docked: false, missing: 0, affordable: false }),
  ).toEqual({ canRepair: false, reason: 'repair_economy_disabled' })
})

test('repairAvailability: invalid amounts reject BEFORE ship/dest/dock (integer hp — never rounded)', () => {
  for (const amount of [0, -3, 2.5, NaN, Number.POSITIVE_INFINITY, 1_000_001]) {
    expect(
      repairAvailability({ ...repairOk(), amount, shipResolved: false, destroyed: true, docked: false }),
    ).toEqual({ canRepair: false, reason: 'invalid_amount' })
  }
  // the 1e6 magnitude cap is inclusive (the server rejects only > 1000000).
  expect(repairAvailability({ ...repairOk(), amount: 1_000_000, missing: 1_000_000 }).canRepair).toBe(true)
})

test('repairAvailability: no resolved ship → ship_not_found (before the destroyed/dock checks)', () => {
  expect(
    repairAvailability({ ...repairOk(), shipResolved: false, destroyed: true, docked: false }),
  ).toEqual({ canRepair: false, reason: 'ship_not_found' })
})

test('repairAvailability: THE SEAM — a destroyed ship → ship_destroyed (before dock/missing/afford)', () => {
  expect(
    repairAvailability({ ...repairOk(), destroyed: true, docked: false, missing: 0, affordable: false }),
  ).toEqual({ canRepair: false, reason: 'ship_destroyed' })
})

test('repairAvailability: not docked → not_docked (before missing/afford)', () => {
  expect(
    repairAvailability({ ...repairOk(), docked: false, missing: 0, affordable: false }),
  ).toEqual({ canRepair: false, reason: 'not_docked' })
})

test('repairAvailability: full hull → nothing_to_repair (before afford)', () => {
  expect(
    repairAvailability({ ...repairOk(), missing: 0, affordable: false }),
  ).toEqual({ canRepair: false, reason: 'nothing_to_repair' })
})

test('repairAvailability: too poor → insufficient_credits (last)', () => {
  expect(repairAvailability({ ...repairOk(), affordable: false })).toEqual({
    canRepair: false,
    reason: 'insufficient_credits',
  })
})

test('repairAvailability: unknown wallet (affordable null) SKIPS the afford precheck → ok (server answers)', () => {
  expect(repairAvailability({ ...repairOk(), affordable: null })).toEqual({ canRepair: true, reason: 'ok' })
})

// ── button-disable policy (the salvage M2 posture) ──────────────────────────────────────────────────
test('repairBlocks: insufficient_credits ADVISES (button stays enabled); everything structural blocks', () => {
  expect(repairBlocks('insufficient_credits')).toBe(false)
  expect(repairBlocks('ok')).toBe(false)
  for (const r of ['repair_economy_disabled', 'invalid_amount', 'ship_not_found', 'ship_destroyed', 'not_docked', 'nothing_to_repair'] as const) {
    expect(repairBlocks(r)).toBe(true)
  }
})

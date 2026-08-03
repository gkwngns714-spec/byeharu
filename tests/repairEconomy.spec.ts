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
  repairDockState,
  repairDockStateLine,
  type ShipHull,
} from '../src/features/ship/repairEconomy'
import { repairReasonMessage } from '../src/features/ship/repairReasonMessage'
import type { FleetPositionPlace } from '../src/features/map/mainshipApi'

// REPAIR-ECON — pure-logic specs for the hull-repair client mirrors (no app/Supabase). Asserts the
// same reject ORDER as THE server repair RPC, repair_ship_hull (migration 0335, which replaced 0201's
// repair_ship_hull_at_port and 0297's repair_main_ship with one verb): the economy gate, then amount
// validation (integer hp — never rounded), then ship, then POSITION (one authority), then
// something-to-repair, then affordability — plus the hull math, the whole-hp clamp, the cost math,
// the strict config fold, and the NON-NEGATIVE rate fold (zero is a price, and it means free).
// Run: `npx playwright test repairEconomy.spec.ts`.

const hull = (over: Partial<ShipHull> = {}): ShipHull => ({ hp: 380, maxHp: 500, status: 'stationary', ...over })

// A fully-repairable input; tests flip one clause at a time (the salvageMarket mold).
const repairOk = () => ({
  flagOn: true,
  amount: 120,
  shipResolved: true,
  atPort: true,
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

test('foldRepairRate: ZERO IS A PRICE AND IT MEANS FREE; only junk/negative folds to null', () => {
  expect(foldRepairRate(0.5)).toBe(0.5)
  expect(foldRepairRate('2')).toBe(2)
  // RED BY CONSTRUCTION against the defect 0335 closed. This fold used to require n > 0, mirroring
  // 0201's server-side `v_per_hp <= 0 -> repair_misconfigured`. The moment the owner set
  // repair_credits_per_hp = 0 to make repairs free, BOTH halves broke at once: the server refused
  // every mend and the desk showed no price. Zero must fold to zero on both sides.
  expect(foldRepairRate(0)).toBe(0)
  expect(foldRepairRate('0')).toBe(0)
  // still fail closed on the shapes that are genuinely unknown or nonsensical.
  expect(foldRepairRate(-1)).toBeNull()
  expect(foldRepairRate('')).toBeNull()
  expect(foldRepairRate(null)).toBeNull()
  expect(foldRepairRate('abc')).toBeNull()
})

test('a ZERO knob prices a real repair at 0 credits end-to-end (free, never "unavailable")', () => {
  const cfg = repairConfigFromRows([
    { key: 'repair_economy_enabled', value: true },
    { key: 'repair_credits_per_hp', value: 0 },
  ])
  expect(cfg.enabled).toBe(true)
  expect(cfg.creditsPerHp).toBe(0)
  // a real cost of 0 — NOT null ("cost unknown"), which is what the old fold produced.
  const cost = repairCostFor(120, cfg.creditsPerHp)
  expect(cost).toBe(0)
  // and a broke player can afford it, so the mirror does not advise insufficient_credits.
  expect(repairAvailability({ ...repairOk(), affordable: 0 >= (cost ?? 1) })).toEqual({
    canRepair: true,
    reason: 'ok',
  })
})

test('a NON-ZERO knob still governs — restoring the price is one knob change, nothing else', () => {
  const cfg = repairConfigFromRows([
    { key: 'repair_economy_enabled', value: true },
    { key: 'repair_credits_per_hp', value: 2.5 },
  ])
  expect(cfg.creditsPerHp).toBe(2.5)
  expect(repairCostFor(120, cfg.creditsPerHp)).toBe(300)
  // a 100-credit wallet can no longer afford it — the same fold, the same mirror, one knob apart.
  expect(repairAvailability({ ...repairOk(), affordable: 100 >= 300 })).toEqual({
    canRepair: false,
    reason: 'insufficient_credits',
  })
})

// ── hull math ──────────────────────────────────────────────────────────────────────────────────────
test('isDestroyed: only status=destroyed is the free-recovery subject', () => {
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

test('repairCostFor: hp × rate; unknown rate or non-positive hp → null; a 0 rate costs 0', () => {
  expect(repairCostFor(120, 0.5)).toBe(60)
  expect(repairCostFor(40, 0.5)).toBe(20)
  expect(repairCostFor(120, null)).toBeNull()
  expect(repairCostFor(0, 0.5)).toBeNull()
  expect(repairCostFor(120, 0)).toBe(0)
})

// ── availability mirror (the 0335 reject order) ─────────────────────────────────────────────────────
test('repairAvailability: everything satisfied → ok', () => {
  expect(repairAvailability(repairOk())).toEqual({ canRepair: true, reason: 'ok' })
})

test('repairAvailability: a dark economy gate wins over everything else in the mirror', () => {
  expect(
    repairAvailability({
      ...repairOk(),
      flagOn: false,
      amount: 0,
      shipResolved: false,
      atPort: false,
      missing: 0,
      affordable: false,
    }),
  ).toEqual({ canRepair: false, reason: 'repair_economy_disabled' })
})

test('repairAvailability: invalid amounts reject BEFORE ship/position (integer hp — never rounded)', () => {
  for (const amount of [0, -3, 2.5, NaN, Number.POSITIVE_INFINITY, 1_000_001]) {
    expect(repairAvailability({ ...repairOk(), amount, shipResolved: false, atPort: false })).toEqual({
      canRepair: false,
      reason: 'invalid_amount',
    })
  }
  // the 1e6 magnitude cap is inclusive (the server rejects only > 1000000).
  expect(repairAvailability({ ...repairOk(), amount: 1_000_000, missing: 1_000_000 }).canRepair).toBe(true)
})

test('repairAvailability: no resolved ship → ship_not_found (before the position check)', () => {
  expect(repairAvailability({ ...repairOk(), shipResolved: false, atPort: false })).toEqual({
    canRepair: false,
    reason: 'ship_not_found',
  })
})

test('repairAvailability: not at a port → not_at_port (before missing/afford)', () => {
  expect(repairAvailability({ ...repairOk(), atPort: false, missing: 0, affordable: false })).toEqual({
    canRepair: false,
    reason: 'not_at_port',
  })
})

test('repairAvailability: full hull → nothing_to_repair (before afford)', () => {
  expect(repairAvailability({ ...repairOk(), missing: 0, affordable: false })).toEqual({
    canRepair: false,
    reason: 'nothing_to_repair',
  })
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

// ── repairDockState (ONE position authority — the fold collapsed to three states in 0335) ───────────
test('repairDockState: docked AND berthed both → at_port; transit/in_space→away; hidden/no-row→unknown', () => {
  // 'docked' = a present fleet at a port.
  expect(repairDockState({ place: 'docked' })).toBe('at_port')
  // BERTHED IS AT A PORT — the 0335 change, and red against the old two-state split. 0201 gated the
  // mend on mainship_resolve_docked_location, which additionally demands a PRESENT FLEET, so a
  // berthed ship answered not_docked while the recovery path (mainship_port_of_ship) called the
  // same ship in-port on the same tick. One authority, one answer.
  expect(repairDockState({ place: 'berthed' })).toBe('at_port')
  // genuinely not at a port — the not_at_port copy is true for these.
  for (const place of ['transit', 'in_space'] as FleetPositionPlace[]) {
    expect(repairDockState({ place })).toBe('away')
  }
  // 'hidden' and a missing row mean WE DO NOT KNOW (fetchMyFleetPositions collapses every error
  // to []) — never 'away': a failed read must not become a confident "take this ship to a port".
  expect(repairDockState({ place: 'hidden' })).toBe('unknown')
  expect(repairDockState(undefined)).toBe('unknown')
})

test('a berthed ship is REPAIRABLE in the mirror (the fleet-less dead end is gone)', () => {
  const verdict = repairAvailability({
    ...repairOk(),
    atPort: repairDockState({ place: 'berthed' }) === 'at_port',
  })
  expect(verdict).toEqual({ canRepair: true, reason: 'ok' })
})

test('repairDockStateLine: one honest sentence per blocked state; silence where no claim is honest', () => {
  // at_port → the mend renders instead; unknown → no claim either way. Both say nothing.
  expect(repairDockStateLine('at_port')).toBeNull()
  expect(repairDockStateLine('unknown')).toBeNull()
  // away → the availability mirror's not_at_port copy VERBATIM (one sentence source: a real server
  // reject shows the same words).
  expect(repairDockStateLine('away')).toBe(repairReasonMessage('not_at_port'))
})

test('a not-at-port fold flows to the not_at_port verdict', () => {
  const verdict = repairAvailability({
    ...repairOk(),
    atPort: repairDockState({ place: 'in_space' }) === 'at_port',
  })
  expect(verdict).toEqual({ canRepair: false, reason: 'not_at_port' })
  expect(repairBlocks(verdict.reason)).toBe(true) // structural: the Repair button hard-disables
})

// ── button-disable policy (the salvage M2 posture) ──────────────────────────────────────────────────
test('repairBlocks: insufficient_credits ADVISES (button stays enabled); everything structural blocks', () => {
  expect(repairBlocks('insufficient_credits')).toBe(false)
  expect(repairBlocks('ok')).toBe(false)
  for (const r of [
    'repair_economy_disabled',
    'invalid_amount',
    'ship_not_found',
    'not_at_port',
    'nothing_to_repair',
  ] as const) {
    expect(repairBlocks(r)).toBe(true)
  }
})

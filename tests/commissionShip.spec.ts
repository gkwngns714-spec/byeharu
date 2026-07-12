import { test, expect } from '@playwright/test'
import {
  commissionAffordability,
  commissionContextFromConfig,
  commissionReasonMessage,
  commissionShortfallMessage,
  formatCredits,
  walletBalanceLabel,
} from '../src/features/ship/commissionShip'

// TEAM-ACTIVATION PREP — pure-logic specs for the dark commission-ship affordance (no app/Supabase).
// Covers the two new pure helpers CommissionShipPanel composes with the EXISTING
// commissionAvailability (already specced in teamRoster.spec.ts): the fail-closed game_config
// coercion (display mirror never more permissive than the server) and the reason→copy map
// (both the server reject vocabulary and the client availability mirror; never a raw code).

// ── commissionContextFromConfig — fail-closed coercion of the four public-read knobs ──────────────
test('context: no rows → dark + the SERVER fallbacks (cap 3 per 0080, price 1000 per 0091, seed 0 per 0093 wallet_ensure)', () => {
  expect(commissionContextFromConfig([])).toEqual({ serverEnabled: false, cap: 3, price: 1000, startingCredits: 0 })
})

test('context: jsonb values coerce (boolean flag, numeric cap/price/seed)', () => {
  expect(
    commissionContextFromConfig([
      { key: 'mainship_additional_commission_enabled', value: true },
      { key: 'max_main_ships_per_player', value: 24 },
      { key: 'main_ship_price', value: 250 },
      { key: 'starting_credits', value: 1000 },
    ]),
  ).toEqual({ serverEnabled: true, cap: 24, price: 250, startingCredits: 1000 })
})

test('context: the flag is STRICT boolean — a truthy non-true value still reads DARK (fail closed)', () => {
  for (const v of ['true', 1, 'yes', {}, [true]]) {
    expect(
      commissionContextFromConfig([{ key: 'mainship_additional_commission_enabled', value: v }]).serverEnabled,
    ).toBe(false)
  }
})

test('context: numeric-string values coerce; junk/null/empty fall back to the server defaults', () => {
  const ctx = commissionContextFromConfig([
    { key: 'max_main_ships_per_player', value: '24' }, // historic numeric-string jsonb shape
    { key: 'main_ship_price', value: '250' },
  ])
  expect(ctx.cap).toBe(24)
  expect(ctx.price).toBe(250)
  const junk = commissionContextFromConfig([
    { key: 'max_main_ships_per_player', value: 'lots' },
    { key: 'main_ship_price', value: null },
  ])
  expect(junk.cap).toBe(3)
  expect(junk.price).toBe(1000)
})

test('context: unrelated keys are ignored (the map is keyed, not positional)', () => {
  expect(
    commissionContextFromConfig([
      { key: 'team_command_enabled', value: true },
      { key: 'enemy_hp_base', value: 14 },
    ]),
  ).toEqual({ serverEnabled: false, cap: 3, price: 1000, startingCredits: 0 })
})

// ── commissionAffordability — the lazy-wallet (0093) effective balance + shortfall ────────────────
// Owner defect: "I can buy a ship even though I have no money?" — the display said Balance 0 for a
// player with NO wallet row, whose effective balance was actually the starting_credits seed.
test('affordability: no wallet row (null) → effective balance = the starting_credits seed, flagged', () => {
  expect(commissionAffordability(null, { startingCredits: 1000, price: 1000 })).toEqual({
    effectiveBalance: 1000,
    fromStartingCredits: true,
    shortfall: 0, // exactly affordable — the seed covers the placeholder price
  })
})

test('affordability: a seeded wallet uses its REAL balance, even when 0 (0 after spending ≠ unseeded)', () => {
  expect(commissionAffordability(0, { startingCredits: 1000, price: 250 })).toEqual({
    effectiveBalance: 0,
    fromStartingCredits: false,
    shortfall: 250,
  })
})

test('affordability: shortfall = max(0, price − effective); surplus never goes negative', () => {
  expect(commissionAffordability(400, { startingCredits: 1000, price: 1000 }).shortfall).toBe(600)
  expect(commissionAffordability(5000, { startingCredits: 1000, price: 1000 }).shortfall).toBe(0)
  // unseeded + a seed smaller than the price → the honest shortfall against the seed
  expect(commissionAffordability(null, { startingCredits: 500, price: 1000 }).shortfall).toBe(500)
})

// ── display strings — grouped digits + the honest "(starting credits)" hint ───────────────────────
test('labels: formatCredits groups thousands; walletBalanceLabel hints ONLY when unseeded', () => {
  expect(formatCredits(1000)).toBe('1,000')
  expect(formatCredits(0)).toBe('0')
  expect(walletBalanceLabel({ effectiveBalance: 1000, fromStartingCredits: true, shortfall: 0 })).toBe(
    '1,000 cr (starting credits)',
  )
  expect(walletBalanceLabel({ effectiveBalance: 250, fromStartingCredits: false, shortfall: 750 })).toBe('250 cr')
})

test('labels: commissionShortfallMessage carries the amount, player copy only (no raw code)', () => {
  expect(commissionShortfallMessage(1500)).toBe('Not enough credits — 1,500 cr short.')
  expect(commissionShortfallMessage(1500)).not.toContain('_')
})

// ── commissionReasonMessage — server rejects + client mirror reasons + unknown fallback ───────────
test('reasons: every SERVER reject of commission_additional_main_ship (0080/0091) maps to copy', () => {
  for (const r of ['not_authenticated', 'additional_commission_disabled', 'no_first_ship', 'ship_cap_reached', 'insufficient_credits', 'unavailable']) {
    const msg = commissionReasonMessage(r)
    expect(msg.length).toBeGreaterThan(0)
    expect(msg).not.toContain('_') // player copy, never the raw code
  }
})

test('reasons: the client availability mirror (gate_dark / cap_reached) maps to the same copy as its server twin', () => {
  expect(commissionReasonMessage('gate_dark')).toBe(commissionReasonMessage('additional_commission_disabled'))
  expect(commissionReasonMessage('cap_reached')).toBe(commissionReasonMessage('ship_cap_reached'))
})

test('reasons: unknown → generic line, never a throw or a raw code', () => {
  expect(commissionReasonMessage('some_future_reason')).toBe('Commissioning unavailable.')
})

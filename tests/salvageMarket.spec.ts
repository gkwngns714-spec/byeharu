import { test, expect } from '@playwright/test'
import {
  clampSellQty,
  salvageConfigFromRows,
  salvageEntries,
  salvageSellAvailability,
  salvageSellBlocks,
  salvageStickyLit,
  salvageWalletDisplay,
  sellTotal,
} from '../src/features/port/salvageMarket'

// SALVAGE-2 — pure-logic specs for the salvage-market client mirrors (no app/Supabase). Asserts
// the same reject ORDER as the server RPC sell_item_at_port (migration 0174): gate FIRST, then
// input validation (integer quantities — never rounded), then ship, then docking, then demand,
// then the balance — plus the qty clamp, the display price math, the strict config fold, and the
// wallet-honesty display. Run: `npx playwright test salvageMarket.spec.ts`.

// A fully-sellable input; tests flip one clause at a time (the haulBoard/teamSend mold).
const sellOk = () => ({
  flagOn: true,
  quantity: 2,
  shipResolved: true,
  docked: true,
  demandActive: true,
  balance: 5 as number | null,
})

test('salvageSellAvailability: everything satisfied → ok', () => {
  expect(salvageSellAvailability(sellOk())).toEqual({ canSell: true, reason: 'ok' })
})

test('salvageSellAvailability: dark gate wins over EVERYTHING (server order: gate first, before any read)', () => {
  expect(
    salvageSellAvailability({ ...sellOk(), flagOn: false, quantity: 0, shipResolved: false, balance: 0 }),
  ).toEqual({ canSell: false, reason: 'salvage_market_disabled' })
})

test('salvageSellAvailability: invalid quantities reject BEFORE ship/dock/demand (the 0174 input-validation slot)', () => {
  for (const quantity of [0, -3, 2.5, NaN, Number.POSITIVE_INFINITY, 1_000_001]) {
    expect(salvageSellAvailability({ ...sellOk(), quantity, shipResolved: false, docked: false })).toEqual({
      canSell: false,
      reason: 'invalid_quantity',
    })
  }
  // the 1e6 magnitude cap is inclusive (the server rejects only > 1000000).
  expect(salvageSellAvailability({ ...sellOk(), quantity: 1_000_000, balance: null }).canSell).toBe(true)
})

test('salvageSellAvailability: no resolved ship → ship_not_found (before docking/demand/balance)', () => {
  expect(salvageSellAvailability({ ...sellOk(), shipResolved: false, docked: false, balance: 0 })).toEqual({
    canSell: false,
    reason: 'ship_not_found',
  })
})

test('salvageSellAvailability: not docked → not_docked (before the demand/balance checks)', () => {
  expect(salvageSellAvailability({ ...sellOk(), docked: false, demandActive: false, balance: 0 })).toEqual({
    canSell: false,
    reason: 'not_docked',
  })
})

test('salvageSellAvailability: no active demand row → no_demand (before the balance check)', () => {
  expect(salvageSellAvailability({ ...sellOk(), demandActive: false, balance: 0 })).toEqual({
    canSell: false,
    reason: 'no_demand',
  })
})

// canSell here is the pure would-the-server-accept MIRROR verdict; the BUTTON disable policy is
// salvageSellBlocks below (review M2) — a shortfall ADVISES, it no longer hard-disables.
test('salvageSellAvailability: short balance → insufficient_items (boundary: balance == qty sells)', () => {
  expect(salvageSellAvailability({ ...sellOk(), quantity: 6, balance: 5 })).toEqual({
    canSell: false,
    reason: 'insufficient_items',
  })
  expect(salvageSellAvailability({ ...sellOk(), quantity: 5, balance: 5 })).toEqual({
    canSell: true,
    reason: 'ok',
  })
  expect(salvageSellAvailability({ ...sellOk(), quantity: 1, balance: 0 })).toEqual({
    canSell: false,
    reason: 'insufficient_items',
  })
})

test('salvageSellAvailability: unknown balance (null) SKIPS the precheck — the server answers itself', () => {
  expect(salvageSellAvailability({ ...sellOk(), quantity: 99, balance: null })).toEqual({
    canSell: true,
    reason: 'ok',
  })
})

// ── salvageSellBlocks — the button-disable policy: ADVISE on shortfall, BLOCK on structure (M2) ──
test('salvageSellBlocks: insufficient_items ADVISES — the button stays enabled (stale-balance honesty)', () => {
  // The docked lifecycleKey does not tick when out-of-band loot settles mid-dock, so a known
  // balance may be stale-low: the shortfall shows as a hint and the SERVER enforces (mapped reject).
  expect(salvageSellBlocks('insufficient_items')).toBe(false)
  expect(salvageSellBlocks('ok')).toBe(false)
})

test('salvageSellBlocks: structurally-invalid states still hard-disable', () => {
  for (const reason of [
    'salvage_market_disabled',
    'invalid_quantity',
    'ship_not_found',
    'not_docked',
    'no_demand',
  ] as const) {
    expect(salvageSellBlocks(reason)).toBe(true)
  }
})

// ── clampSellQty — the 1..balance stepper clamp (whole items, floored, never rounded up) ────────
test('clampSellQty: in-band whole values pass through', () => {
  expect(clampSellQty(1, 5)).toBe(1)
  expect(clampSellQty(3, 5)).toBe(3)
  expect(clampSellQty(5, 5)).toBe(5)
})

test('clampSellQty: below the floor / non-finite → 1', () => {
  expect(clampSellQty(0, 5)).toBe(1)
  expect(clampSellQty(-4, 5)).toBe(1)
  expect(clampSellQty(NaN, 5)).toBe(1)
  expect(clampSellQty(Number.POSITIVE_INFINITY, 5)).toBe(1) // non-finite input → the safe floor, like NaN
})

test('clampSellQty: fractional input FLOORS (the 0174 integer posture — never rounds up)', () => {
  expect(clampSellQty(2.9, 5)).toBe(2)
  expect(clampSellQty(0.4, 5)).toBe(1)
})

test('clampSellQty: above the balance clamps to the balance (floored)', () => {
  expect(clampSellQty(9, 5)).toBe(5)
  expect(clampSellQty(9, 5.7)).toBe(5)
})

test('clampSellQty: zero/negative balance keeps the floor at 1 (the shortfall advises; the stepper never shows 0)', () => {
  expect(clampSellQty(3, 0)).toBe(1)
  expect(clampSellQty(3, -2)).toBe(1)
})

test('clampSellQty: unknown balance (null) → no upper clamp (the server owns insufficiency)', () => {
  expect(clampSellQty(250, null)).toBe(250)
  expect(clampSellQty(0, null)).toBe(1)
})

// ── sellTotal — display price math (qty × unit; the server computes the receipted total) ────────
test('sellTotal: qty × unit price (the seeded 0174 numbers as subjects)', () => {
  expect(sellTotal(3, 8)).toBe(24) // 3 scrap at Slagworks
  expect(sellTotal(1, 16)).toBe(16) // 1 pirate_alloy at Slagworks
  expect(sellTotal(0, 20)).toBe(0)
})

test('sellTotal: non-finite or negative inputs → 0 (never NaN into the render path)', () => {
  expect(sellTotal(NaN, 8)).toBe(0)
  expect(sellTotal(3, NaN)).toBe(0)
  expect(sellTotal(-1, 8)).toBe(0)
  expect(sellTotal(3, -8)).toBe(0)
})

// ── salvageEntries — demand ⋈ balances, display-name sorted (the inventoryEntries idiom) ────────
test('salvageEntries: merges balances (missing item → 0 — zero-stock rows STAY on the buy-list)', () => {
  const rows = [
    { item_id: 'scrap', unit_price: 8 },
    { item_id: 'pirate_alloy', unit_price: 16 },
  ]
  const entries = salvageEntries(rows, { scrap: 3 })
  expect(entries).toEqual([
    { item_id: 'pirate_alloy', unit_price: 16, balance: 0 },
    { item_id: 'scrap', unit_price: 8, balance: 3 },
  ])
})

test('salvageEntries: sorted by player-facing display name, raw id tiebreak; null balances → 0', () => {
  const rows = [
    { item_id: 'weapon_parts', unit_price: 13 },
    { item_id: 'engine_parts', unit_price: 14 },
    { item_id: 'repair_parts', unit_price: 12 },
  ]
  expect(salvageEntries(rows, null).map((e) => e.item_id)).toEqual([
    'engine_parts',
    'repair_parts',
    'weapon_parts',
  ])
  expect(salvageEntries(rows, null).every((e) => e.balance === 0)).toBe(true)
})

test('salvageEntries: empty demand → [] (the server list is the truth — no client filter/hardcode)', () => {
  expect(salvageEntries([], { scrap: 3 })).toEqual([])
})

// ── salvageStickyLit — the render gate across re-reads within one mount (review M1) ─────────────
test('salvageStickyLit: FIRST MOUNT stays dark until a positive read (the dark-leak guarantee untouched)', () => {
  expect(salvageStickyLit(false, false)).toBe(false) // pre-flip production: never renders
  expect(salvageStickyLit(false, true)).toBe(true) // a positive strict read lights it
})

test('salvageStickyLit: once lit, a failed/dark config re-read keeps the panel RENDERED (note preserved)', () => {
  // The post-sale refresh path: sale succeeded → success note set → refresh's game_config read
  // blips (error → [] → enabled:false). The panel must NOT unmount (which would vanish the note);
  // it stays rendered in the MarketPanel stay-rendered posture — the server remains the control.
  expect(salvageStickyLit(true, false)).toBe(true)
  expect(salvageStickyLit(true, true)).toBe(true)
})

// ── salvageConfigFromRows — the STRICT dark-gate fold (public-read game_config, jsonb values) ───
test('salvageConfigFromRows: jsonb true lights the gate; anything else reads DARK (fail closed)', () => {
  expect(salvageConfigFromRows([{ key: 'salvage_market_enabled', value: true }]).enabled).toBe(true)
  // strict boolean — the commissionContextFromConfig posture: 'true' the STRING stays dark.
  expect(salvageConfigFromRows([{ key: 'salvage_market_enabled', value: 'true' }]).enabled).toBe(false)
  expect(salvageConfigFromRows([{ key: 'salvage_market_enabled', value: false }]).enabled).toBe(false)
  expect(salvageConfigFromRows([]).enabled).toBe(false) // read error → [] → dark
})

test('salvageConfigFromRows: starting_credits coerces number/numeric-string; absent/junk → null', () => {
  expect(salvageConfigFromRows([{ key: 'starting_credits', value: 250 }]).startingCredits).toBe(250)
  expect(salvageConfigFromRows([{ key: 'starting_credits', value: '250' }]).startingCredits).toBe(250)
  expect(salvageConfigFromRows([]).startingCredits).toBeNull()
  expect(salvageConfigFromRows([{ key: 'starting_credits', value: 'junk' }]).startingCredits).toBeNull()
})

// ── salvageWalletDisplay — the getWalletBalance sentinel semantics, incl. 'error' ───────────────
test("salvageWalletDisplay: 'error'/unread → honest '—' (never a false 0)", () => {
  expect(salvageWalletDisplay('error', 250)).toBe('—')
  expect(salvageWalletDisplay(undefined, 250)).toBe('—')
})

test('salvageWalletDisplay: no wallet row (lazy 0093 seed) → the effective starting credits, labeled', () => {
  expect(salvageWalletDisplay(null, 250)).toBe('250 (starting credits)')
  expect(salvageWalletDisplay(null, null)).toBe('—') // seed unknown → no claim
})

test('salvageWalletDisplay: a seeded wallet shows its grouped balance', () => {
  expect(salvageWalletDisplay(1250, 250)).toBe('1,250')
  expect(salvageWalletDisplay(0, 250)).toBe('0') // a REAL zero row is a real 0 — not '—'
})

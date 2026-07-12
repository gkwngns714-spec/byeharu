import { test, expect } from '@playwright/test'
import {
  activeOrderCount,
  bestCaptainLevel,
  captainGateState,
  hullGateState,
  hullOrderViews,
  shipyardConfigFromRows,
  shipyardEffectiveCredits,
  shipyardOrderAvailability,
  shipyardOrderBlocks,
  shipyardRecipeEntries,
  shipyardRejectNote,
  shipyardSuccessNote,
  type BuildOrderRow,
} from '../src/features/port/shipyard'
import { salvageWalletDisplay } from '../src/features/port/salvageMarket'

// SHIPYARD-3 — pure-logic specs for the shipyard client mirrors (no app/Supabase). Asserts the
// same reject ORDER as the server RPC start_hull_build (migration 0188, wrapper-code vocabulary):
// gate FIRST, then the hull prerequisite, then the captain level, then the shared queue cap, then
// ingredients (in the server's pinned item_id order), then credits — plus the strict config fold,
// the null-skip honesty of every unknown input, the gate-view honesty (no false greens), the
// catalog/orders view-models, and the receipted success note. The 0185 T1 seeds (bulk_hauler /
// strike_corvette, 400 cr / 3600 s, NULL gates) are the subjects where real numbers help.
// Run: `npx playwright test shipyard.spec.ts`.

// A fully-orderable input over the seeded bulk_hauler bill; tests flip one clause at a time (the
// salvageMarket/haulBoard mold).
const HAULER_BILL = [
  { item_id: 'ore', qty: 24 },
  { item_id: 'crystal', qty: 6 },
  { item_id: 'engine_parts', qty: 6 },
  { item_id: 'scrap', qty: 12 },
  { item_id: 'blueprint_fragment', qty: 2 },
]
const FULL_STOCK = { ore: 24, crystal: 6, engine_parts: 6, scrap: 12, blueprint_fragment: 2 }
const orderOk = () => ({
  flagOn: true,
  requiredHullTypeId: null as string | null,
  ownedHullTypeIds: ['starter_frigate'] as string[] | null,
  requiredCaptainLevel: null as number | null,
  bestCaptainLevel: null as number | null,
  queuedCount: 0 as number | null,
  maxOrders: 5 as number | null,
  ingredients: HAULER_BILL,
  balances: { ...FULL_STOCK } as Record<string, number> | null,
  creditsCost: 400,
  credits: 400 as number | null,
})

// ── shipyardOrderAvailability — the 0188 reject order, one clause at a time ─────────────────────
test('shipyardOrderAvailability: everything satisfied → ok (boundary: exact stock + exact credits order)', () => {
  expect(shipyardOrderAvailability(orderOk())).toEqual({ canOrder: true, reason: 'ok' })
})

test('shipyardOrderAvailability: dark gate wins over EVERYTHING (server order: gate first, before any read)', () => {
  expect(
    shipyardOrderAvailability({
      ...orderOk(),
      flagOn: false,
      requiredHullTypeId: 'bulk_hauler',
      ownedHullTypeIds: [],
      queuedCount: 9,
      balances: {},
      credits: 0,
    }),
  ).toEqual({ canOrder: false, reason: 'feature_disabled' })
})

test('shipyardOrderAvailability: unmet hull prerequisite rejects BEFORE captain/cap/items/credits (the 0188 §6 slot)', () => {
  expect(
    shipyardOrderAvailability({
      ...orderOk(),
      requiredHullTypeId: 'bulk_hauler',
      ownedHullTypeIds: ['starter_frigate'],
      requiredCaptainLevel: 3,
      bestCaptainLevel: 1,
      queuedCount: 9,
      balances: {},
      credits: 0,
    }),
  ).toEqual({ canOrder: false, reason: 'hull_prerequisite_not_met' })
  // owned → the clause passes through to the next reject.
  expect(
    shipyardOrderAvailability({
      ...orderOk(),
      requiredHullTypeId: 'bulk_hauler',
      ownedHullTypeIds: ['starter_frigate', 'bulk_hauler'],
    }),
  ).toEqual({ canOrder: true, reason: 'ok' })
})

test('shipyardOrderAvailability: captain level too low rejects BEFORE cap/items/credits', () => {
  expect(
    shipyardOrderAvailability({
      ...orderOk(),
      requiredCaptainLevel: 3,
      bestCaptainLevel: 2,
      queuedCount: 9,
      balances: {},
      credits: 0,
    }),
  ).toEqual({ canOrder: false, reason: 'captain_level_too_low' })
  // boundary: level == required meets the gate (the server's `level >=` arm).
  expect(
    shipyardOrderAvailability({ ...orderOk(), requiredCaptainLevel: 3, bestCaptainLevel: 3 }),
  ).toEqual({ canOrder: true, reason: 'ok' })
})

test('shipyardOrderAvailability: full queue → queue_full (before items/credits; boundary: count == max)', () => {
  expect(
    shipyardOrderAvailability({ ...orderOk(), queuedCount: 5, maxOrders: 5, balances: {}, credits: 0 }),
  ).toEqual({ canOrder: false, reason: 'queue_full' })
  expect(shipyardOrderAvailability({ ...orderOk(), queuedCount: 4, maxOrders: 5 })).toEqual({
    canOrder: true,
    reason: 'ok',
  })
})

test('shipyardOrderAvailability: ingredient shortfall → insufficient_items with the FIRST item in item_id order (the server\'s pinned order)', () => {
  // Both blueprint_fragment ('b…') and scrap short — item_id order reports blueprint_fragment
  // first regardless of the bill's declaration order (the spec input is deliberately unsorted).
  expect(
    shipyardOrderAvailability({
      ...orderOk(),
      balances: { ...FULL_STOCK, scrap: 0, blueprint_fragment: 1 },
      credits: 0,
    }),
  ).toEqual({ canOrder: false, reason: 'insufficient_items', itemId: 'blueprint_fragment' })
  // a missing balance key reads as 0 (the fetchMyItemBalances shape: absent item → no row).
  const noOre = { ...FULL_STOCK } as Record<string, number>
  delete noOre.ore
  expect(shipyardOrderAvailability({ ...orderOk(), balances: noOre })).toEqual({
    canOrder: false,
    reason: 'insufficient_items',
    itemId: 'ore',
  })
})

test('shipyardOrderAvailability: short credits → insufficient_credits (the LAST clause; boundary: exact price passes)', () => {
  expect(shipyardOrderAvailability({ ...orderOk(), credits: 399 })).toEqual({
    canOrder: false,
    reason: 'insufficient_credits',
  })
  expect(shipyardOrderAvailability({ ...orderOk(), credits: 400 })).toEqual({ canOrder: true, reason: 'ok' })
})

test('shipyardOrderAvailability: EVERY unknown (null) input SKIPS its clause — the server answers itself', () => {
  // unknown owned hulls / captain level / queue / balances / credits, with a gated recipe: ok.
  expect(
    shipyardOrderAvailability({
      ...orderOk(),
      requiredHullTypeId: 'bulk_hauler',
      ownedHullTypeIds: null,
      requiredCaptainLevel: 3,
      bestCaptainLevel: null,
      queuedCount: null,
      maxOrders: null,
      balances: null,
      credits: null,
    }),
  ).toEqual({ canOrder: true, reason: 'ok' })
})

// ── shipyardOrderBlocks — the button-disable policy: ONLY the dark gate blocks (M2, taken whole) ─
test('shipyardOrderBlocks: only feature_disabled hard-disables; every player-state verdict ADVISES', () => {
  expect(shipyardOrderBlocks('feature_disabled')).toBe(true)
  for (const reason of [
    'ok',
    'hull_prerequisite_not_met',
    'captain_level_too_low',
    'queue_full',
    'insufficient_items',
    'insufficient_credits',
  ] as const) {
    // balances/credits/queue/gates can all be STALE snapshots — the server enforces under lock.
    expect(shipyardOrderBlocks(reason)).toBe(false)
  }
})

// ── shipyardConfigFromRows — the STRICT dark-gate fold (public-read game_config, jsonb values) ──
test('shipyardConfigFromRows: jsonb true lights the gate; anything else reads DARK (fail closed)', () => {
  expect(shipyardConfigFromRows([{ key: 'shipyard_enabled', value: true }]).enabled).toBe(true)
  // strict boolean — the commissionContextFromConfig posture: 'true' the STRING stays dark.
  expect(shipyardConfigFromRows([{ key: 'shipyard_enabled', value: 'true' }]).enabled).toBe(false)
  expect(shipyardConfigFromRows([{ key: 'shipyard_enabled', value: false }]).enabled).toBe(false)
  expect(shipyardConfigFromRows([]).enabled).toBe(false) // read error → [] → dark
})

test('shipyardConfigFromRows: starting_credits rides the ONE extracted fold (number/numeric-string; junk → null)', () => {
  expect(shipyardConfigFromRows([{ key: 'starting_credits', value: 250 }]).startingCredits).toBe(250)
  expect(shipyardConfigFromRows([{ key: 'starting_credits', value: '250' }]).startingCredits).toBe(250)
  expect(shipyardConfigFromRows([]).startingCredits).toBeNull()
  expect(shipyardConfigFromRows([{ key: 'starting_credits', value: 'junk' }]).startingCredits).toBeNull()
})

test('shipyardConfigFromRows: max_build_orders coerces to a whole positive count; absent/junk → null (NEVER a client hardcode of the server\'s 5)', () => {
  expect(shipyardConfigFromRows([{ key: 'max_build_orders', value: 5 }]).maxBuildOrders).toBe(5)
  expect(shipyardConfigFromRows([{ key: 'max_build_orders', value: '3' }]).maxBuildOrders).toBe(3)
  expect(shipyardConfigFromRows([{ key: 'max_build_orders', value: 0 }]).maxBuildOrders).toBeNull()
  expect(shipyardConfigFromRows([{ key: 'max_build_orders', value: 'junk' }]).maxBuildOrders).toBeNull()
  expect(shipyardConfigFromRows([]).maxBuildOrders).toBeNull() // → the cap precheck is skipped
})

// ── shipyardEffectiveCredits — the wallet sentinels feed the PRECHECK honestly ──────────────────
test("shipyardEffectiveCredits: 'error'/unread → null (unknown — the credits precheck is SKIPPED)", () => {
  expect(shipyardEffectiveCredits('error', 250)).toBeNull()
  expect(shipyardEffectiveCredits(undefined, 250)).toBeNull()
})

test('shipyardEffectiveCredits: no wallet row (lazy 0093 seed) → the starting-credits seed; seed unknown → null', () => {
  expect(shipyardEffectiveCredits(null, 250)).toBe(250)
  expect(shipyardEffectiveCredits(null, null)).toBeNull()
})

test('shipyardEffectiveCredits: a seeded wallet is its own balance (a REAL 0 stays 0 — it prechecks)', () => {
  expect(shipyardEffectiveCredits(1250, 250)).toBe(1250)
  expect(shipyardEffectiveCredits(0, 250)).toBe(0)
})

// The wallet DISPLAY string is salvageWalletDisplay REUSED VERBATIM (one fold, one display helper
// — the salvage review flagged the duplicate starting-credits folds; this panel adds none). Its
// full battery lives in salvageMarket.spec.ts; these two lines pin the reuse contract here.
test('wallet display reuse: the shipyard credits row wears the exact salvage sentinel semantics', () => {
  expect(salvageWalletDisplay('error', 250)).toBe('—')
  expect(salvageWalletDisplay(null, 250)).toBe('250 (starting credits)')
})

// ── gate views — HONEST (no false greens; unknown → the static requirement line) ───────────────
test('hullGateState: NULL gate → none (both T1 seeds); owned/absent answer met/unmet; unreadable → unknown', () => {
  expect(hullGateState(null, null)).toBe('none')
  expect(hullGateState('bulk_hauler', ['starter_frigate', 'bulk_hauler'])).toBe('met')
  expect(hullGateState('bulk_hauler', ['starter_frigate'])).toBe('unmet')
  expect(hullGateState('bulk_hauler', null)).toBe('unknown') // own-ship read failed → no claim
})

test('captainGateState: NULL gate → none; known level answers met/unmet (boundary ==); captains dark → unknown', () => {
  expect(captainGateState(null, null)).toBe('none')
  expect(captainGateState(3, 3)).toBe('met')
  expect(captainGateState(3, 2)).toBe('unmet')
  // get_my_captain_instances is captain-gate-DARK today → the STATIC requirement line, no claim.
  expect(captainGateState(3, null)).toBe('unknown')
})

test('bestCaptainLevel: dark/error roster → null; EMPTY lit roster → 0 (honestly unmet); levels → max; level-less rows → null', () => {
  expect(bestCaptainLevel(null)).toBeNull()
  expect(bestCaptainLevel([])).toBe(0)
  expect(bestCaptainLevel([{ level: 2 }, { level: 5 }, { level: 1 }])).toBe(5)
  // a pre-0181 envelope shape (captains without level fields) is UNKNOWN — never a false unmet.
  expect(bestCaptainLevel([{}, {}])).toBeNull()
})

// ── shipyardRecipeEntries — recipes ⋈ ingredients ⋈ hull names (the salvageEntries idiom) ───────
const T1_RECIPES = [
  {
    hull_type_id: 'strike_corvette',
    credits_cost: 400,
    build_seconds: 3600,
    required_hull_type_id: null,
    required_captain_level: null,
  },
  {
    hull_type_id: 'bulk_hauler',
    credits_cost: 400,
    build_seconds: 3600,
    required_hull_type_id: null,
    required_captain_level: null,
  },
]
const T1_NAMES = { bulk_hauler: 'Mule-class Hauler', strike_corvette: 'Talon-class Corvette' }

test('shipyardRecipeEntries: joins bills per hull, pins ingredient item_id order, sorts by display name', () => {
  const entries = shipyardRecipeEntries(
    T1_RECIPES,
    [
      // deliberately NOT in item_id order — the view-model pins it (the server\'s spend order).
      { hull_type_id: 'bulk_hauler', item_id: 'ore', qty: 24 },
      { hull_type_id: 'bulk_hauler', item_id: 'blueprint_fragment', qty: 2 },
      { hull_type_id: 'strike_corvette', item_id: 'weapon_parts', qty: 6 },
      { hull_type_id: 'strike_corvette', item_id: 'ore', qty: 16 },
    ],
    T1_NAMES,
  )
  expect(entries.map((e) => e.hull_type_id)).toEqual(['bulk_hauler', 'strike_corvette']) // Mule < Talon
  expect(entries[0].name).toBe('Mule-class Hauler')
  expect(entries[0].ingredients).toEqual([
    { item_id: 'blueprint_fragment', qty: 2 },
    { item_id: 'ore', qty: 24 },
  ])
  expect(entries[1].ingredients.map((i) => i.item_id)).toEqual(['ore', 'weapon_parts'])
})

test('shipyardRecipeEntries: a hull missing from the name register degrades to the honest title-cased id', () => {
  const entries = shipyardRecipeEntries(T1_RECIPES, [], {})
  expect(entries.map((e) => e.name)).toEqual(['Bulk Hauler', 'Strike Corvette'])
})

test('shipyardRecipeEntries: empty catalog → [] (the server list is the truth — no client hardcode)', () => {
  expect(shipyardRecipeEntries([], [], T1_NAMES)).toEqual([])
})

// ── hullOrderViews / activeOrderCount — the owner build_orders projections ──────────────────────
const ORDERS: BuildOrderRow[] = [
  { id: 'b', hull_type_id: 'bulk_hauler', status: 'waiting', queued_at: '2026-07-13T10:00:00Z' },
  { id: 'a', hull_type_id: null, status: 'waiting', queued_at: '2026-07-13T09:00:00Z' }, // a UNIT order
  { id: 'c', hull_type_id: 'strike_corvette', status: 'active', queued_at: '2026-07-13T08:00:00Z' },
  { id: 'd', hull_type_id: 'bulk_hauler', status: 'completed', queued_at: '2026-07-12T08:00:00Z' }, // terminal
]

test('hullOrderViews: HULL rows only, non-terminal only, oldest first; waiting → Waiting, active → Building', () => {
  const views = hullOrderViews(ORDERS, T1_NAMES)
  expect(views.map((v) => v.id)).toEqual(['c', 'b']) // unit row and terminal row excluded; queue order
  expect(views[0]).toEqual({
    id: 'c',
    hull_type_id: 'strike_corvette',
    name: 'Talon-class Corvette',
    statusLabel: 'Building',
    queued_at: '2026-07-13T08:00:00Z',
  })
  expect(views[1].statusLabel).toBe('Waiting')
})

test('activeOrderCount: counts waiting+active across BOTH kinds (one queue, one cap — 0188 §7)', () => {
  expect(activeOrderCount(ORDERS)).toBe(3) // the unit order counts toward the shared cap too
  expect(activeOrderCount([])).toBe(0)
})

// ── shipyardSuccessNote — SERVER-receipted values only (never client math) ──────────────────────
test('shipyardSuccessNote: the receipted credits + exact bill, in the receipt\'s own order', () => {
  expect(
    shipyardSuccessNote({
      credits_spent: 400,
      ingredients_spent: [
        { item_id: 'blueprint_fragment', quantity: 2 },
        { item_id: 'ore', quantity: 24 },
      ],
    }),
  ).toBe('Build queued — spent 400 credits + Blueprint Fragment ×2, Ore ×24.')
})

test('shipyardSuccessNote: an idempotent replay reads as the ORIGINAL order (nothing spent twice)', () => {
  expect(
    shipyardSuccessNote({
      idempotent_replay: true,
      credits_spent: 400,
      ingredients_spent: [{ item_id: 'ore', quantity: 16 }],
    }),
  ).toBe('Build already queued — original order: 400 credits + Ore ×16.')
})

test('shipyardSuccessNote: an empty receipted bill shows credits only (defensive — no dangling separator)', () => {
  expect(shipyardSuccessNote({ credits_spent: 1250, ingredients_spent: [] })).toBe(
    'Build queued — spent 1,250 credits.',
  )
})

// ── shipyardRejectNote — mapped copy + the SERVER's reject context (0188's truthfulness channel) ─
test('shipyardRejectNote: each context-carrying code appends the SERVER envelope\'s own numbers/ids', () => {
  expect(shipyardRejectNote({ code: 'insufficient_items', item_id: 'blueprint_fragment', have: 1, need: 2 })).toBe(
    'Not enough materials to start this build. (Blueprint Fragment: have 1, need 2)',
  )
  expect(shipyardRejectNote({ code: 'insufficient_credits', need: 400 })).toBe(
    'Not enough credits to start this build. (need 400)',
  )
  // queue_full's envelope carries only max — the reject MEANS the queue is at it (server-truthful).
  expect(shipyardRejectNote({ code: 'queue_full', max: 5 })).toBe(
    'Your build queue is full. (5 of 5 slots used)',
  )
  // gate identities: the register name when known, the honest title-case fallback otherwise.
  expect(
    shipyardRejectNote(
      { code: 'hull_prerequisite_not_met', required_hull_type_id: 'bulk_hauler' },
      { bulk_hauler: 'Mule-class Hauler' },
    ),
  ).toBe('You must own the prerequisite hull first. (requires Mule-class Hauler)')
  expect(shipyardRejectNote({ code: 'hull_prerequisite_not_met', required_hull_type_id: 'bulk_hauler' })).toBe(
    'You must own the prerequisite hull first. (requires Bulk Hauler)',
  )
  expect(shipyardRejectNote({ code: 'captain_level_too_low', required_captain_level: 3 })).toBe(
    'A higher-level captain is required. (requires captain level 3)',
  )
})

test('shipyardRejectNote: ABSENT context leaves the mapped base copy unchanged (additive-only; partial envelopes degrade)', () => {
  expect(shipyardRejectNote({ code: 'insufficient_items' })).toBe('Not enough materials to start this build.')
  expect(shipyardRejectNote({ code: 'insufficient_items', item_id: 'ore', have: 1 })).toBe(
    'Not enough materials to start this build.', // need missing → no partial parenthetical
  )
  expect(shipyardRejectNote({ code: 'insufficient_credits' })).toBe('Not enough credits to start this build.')
  expect(shipyardRejectNote({ code: 'queue_full' })).toBe('Your build queue is full.')
  expect(shipyardRejectNote({ code: 'hull_prerequisite_not_met' })).toBe(
    'You must own the prerequisite hull first.',
  )
  expect(shipyardRejectNote({ code: 'captain_level_too_low' })).toBe('A higher-level captain is required.')
})

test('shipyardRejectNote: context-less codes and the transport fallback stay the plain mapped/generic line', () => {
  expect(shipyardRejectNote({ code: 'feature_disabled' })).toBe('The shipyard is not open yet.')
  expect(shipyardRejectNote({ code: 'unavailable' })).toBe('Shipyard unavailable.')
  expect(shipyardRejectNote({})).toBe('Shipyard unavailable.') // no code at all → the generic line
})

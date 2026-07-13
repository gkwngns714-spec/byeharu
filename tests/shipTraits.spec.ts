import { test, expect } from '@playwright/test'
import {
  shipTraitCards,
  shipTraitsEnabledFromConfig,
  traitEffects,
  type MainShipTraitRow,
  type ShipTraitTypeRow,
} from '../src/features/ship/shipTraits'
import { strictConfigFlag } from '../src/lib/gameConfigFold'

// SOUL-2 — pure-logic specs for the dossier TRAITS section (no app/Supabase). Asserts the house
// mold: the STRICT jsonb-true config fold (the shared strictConfigFlag — the commission/salvage
// posture, now ONE implementation), the fail-closed instance×catalog join (unknown type → muted
// line, never a crash), and the stat-effect formatter (signs, zero-skip, percent for the
// multiplier keys, hp_mult as a hull percent only when ≠ 1). The client renders STORED rows
// only — no derivation logic exists here to test, by design (the server-truth law).
// Run: `npx playwright test shipTraits.spec.ts`.

// ── the strict fold (shared helper + the SOUL-2 wrapper) ─────────────────────────────────────────

test('fold: ONLY jsonb true reads as lit', () => {
  expect(shipTraitsEnabledFromConfig([{ key: 'ship_traits_enabled', value: true }])).toBe(true)
})

test('fold: everything else fails CLOSED to dark', () => {
  for (const value of ['true', 1, 'enabled', {}, [], null, undefined, false]) {
    expect(shipTraitsEnabledFromConfig([{ key: 'ship_traits_enabled', value }])).toBe(false)
  }
  expect(shipTraitsEnabledFromConfig([])).toBe(false) // failed config read → [] → dark
  expect(shipTraitsEnabledFromConfig([{ key: 'other_flag', value: true }])).toBe(false)
  // duplicate key (unreachable — key is a PK — but the direction is pinned): LAST wins, exactly
  // the original commission Map fold — an any-true-wins scan would fail OPEN here.
  expect(
    shipTraitsEnabledFromConfig([
      { key: 'ship_traits_enabled', value: true },
      { key: 'ship_traits_enabled', value: false },
    ]),
  ).toBe(false)
})

test('fold: the shared helper is key-scoped (a different lit flag never leaks in)', () => {
  const rows = [
    { key: 'salvage_market_enabled', value: true },
    { key: 'ship_traits_enabled', value: false },
  ]
  expect(strictConfigFlag(rows, 'salvage_market_enabled')).toBe(true)
  expect(strictConfigFlag(rows, 'ship_traits_enabled')).toBe(false)
})

// ── the stat-effect formatter ────────────────────────────────────────────────────────────────────

test('effects: flat keys render signed, in the pinned vocabulary order, with buff/debuff tone', () => {
  // jsonb object order deliberately scrambled — display order must be the pinned vocabulary.
  expect(traitEffects({ defense: -3, attack: 6 }, 1.0)).toEqual([
    { label: '+6 attack', tone: 'positive' },
    { label: '-3 defense', tone: 'negative' },
  ])
})

test('effects: speed_mult_bonus renders as a signed percent labeled speed', () => {
  // tuned_thrusters (0186 seed): +8% speed, -3 cargo — cargo (flat) precedes speed_mult_bonus.
  expect(traitEffects({ speed_mult_bonus: 0.08, cargo: -3 }, 1.0)).toEqual([
    { label: '-3 cargo', tone: 'negative' },
    { label: '+8% speed', tone: 'positive' },
  ])
  // reinforced_plating: the negative percent (float noise like 0.08*1000=80.000…07 must not leak).
  expect(traitEffects({ defense: 8, speed_mult_bonus: -0.04 }, 1.0)).toEqual([
    { label: '+8 defense', tone: 'positive' },
    { label: '-4% speed', tone: 'negative' },
  ])
})

test('effects: hp_mult ≠ 1 appends a hull percent LAST; 1.0 appends nothing', () => {
  // veteran_frame (0186 seed): defense 5 + the sole hp_mult 1.08 carrier.
  expect(traitEffects({ defense: 5 }, 1.08)).toEqual([
    { label: '+5 defense', tone: 'positive' },
    { label: '+8% hull', tone: 'positive' },
  ])
  expect(traitEffects({}, 1.0)).toEqual([])
  // numeric arrives as a STRING over PostgREST → still coerced, still formatted.
  expect(traitEffects({}, '1.08')).toEqual([{ label: '+8% hull', tone: 'positive' }])
  // sub-1 hull (unreachable today — hp_mult >= 1.0 by the 0186 CHECK — but pinned so a relaxed
  // CHECK can never render a hull debuff in green): negative percent, danger tone.
  expect(traitEffects({}, '0.92')).toEqual([{ label: '-8% hull', tone: 'negative' }])
})

test('effects: zero values are SKIPPED (a zero effect is no effect)', () => {
  expect(traitEffects({ attack: 0, defense: 4 }, 1.0)).toEqual([{ label: '+4 defense', tone: 'positive' }])
  // a multiplier that ROUNDS to 0% takes the same skip path — never a '+0%' token in the DOM.
  expect(traitEffects({ speed_mult_bonus: 0.0004 }, 1.0)).toEqual([])
  expect(traitEffects({}, 1.0004)).toEqual([])
})

test('effects: malformed shapes collapse quietly — never a throw, never NaN', () => {
  expect(traitEffects(null, 1.0)).toEqual([])
  expect(traitEffects('{"attack":6}', 1.0)).toEqual([]) // a string is not the parsed jsonb object
  expect(traitEffects([6], 1.0)).toEqual([])
  expect(traitEffects({ attack: 'six', defense: NaN, scan: Infinity }, 1.0)).toEqual([])
  expect(traitEffects({ attack: 2 }, 'veteran')).toEqual([{ label: '+2 attack', tone: 'positive' }])
  expect(traitEffects({ attack: 2 }, NaN)).toEqual([{ label: '+2 attack', tone: 'positive' }])
})

test('effects: a key outside the vocabulary still renders honestly (underscores → spaces, after the pinned set)', () => {
  expect(traitEffects({ attack: 1, warp_field: 2 }, 1.0)).toEqual([
    { label: '+1 attack', tone: 'positive' },
    { label: '+2 warp field', tone: 'positive' },
  ])
})

// ── the view-model join ──────────────────────────────────────────────────────────────────────────

const catalog: ShipTraitTypeRow[] = [
  {
    trait_type_id: 'hungry_guns',
    name: 'Hungry Guns',
    description: 'Her mounts were bored out for heavier batteries than the class allows.',
    stats_json: { attack: 6, defense: -3 },
    hp_mult: 1.0,
  },
  {
    trait_type_id: 'veteran_frame',
    name: 'Veteran Frame',
    description: 'Old bones hold.',
    stats_json: { defense: 5 },
    hp_mult: 1.08,
  },
]

test('cards: joins stored rows against the catalog, ordered by slot ascending', () => {
  const rows: MainShipTraitRow[] = [
    { slot: 2, trait_type_id: 'hungry_guns' },
    { slot: 1, trait_type_id: 'veteran_frame' },
  ]
  const cards = shipTraitCards(rows, catalog)
  expect(cards.map((c) => c.slot)).toEqual([1, 2])
  expect(cards[0]).toEqual({
    kind: 'trait',
    slot: 1,
    trait_type_id: 'veteran_frame',
    name: 'Veteran Frame',
    description: 'Old bones hold.',
    effects: [
      { label: '+5 defense', tone: 'positive' },
      { label: '+8% hull', tone: 'positive' },
    ],
  })
  expect(cards[1].kind).toBe('trait')
})

test('cards: an unknown trait_type_id fails CLOSED to a muted unknown card — never a crash, never dropped', () => {
  const rows: MainShipTraitRow[] = [
    { slot: 1, trait_type_id: 'hungry_guns' },
    { slot: 2, trait_type_id: 'not_in_catalog' },
  ]
  const cards = shipTraitCards(rows, catalog)
  expect(cards).toHaveLength(2)
  expect(cards[1]).toEqual({ kind: 'unknown', slot: 2, trait_type_id: 'not_in_catalog' })
})

test('cards: no stored rows → [] (the dossier hides the section — it never invents a soul)', () => {
  expect(shipTraitCards([], catalog)).toEqual([])
})

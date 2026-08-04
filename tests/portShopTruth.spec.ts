import { test, expect } from '@playwright/test'
import {
  NO_LIVE_EFFECT_NOTE,
  offerEffectStanding,
  offerStatChips,
  type ShopOffer,
} from '../src/features/port/portShop.ts'
import { DORMANT_STAT_IDS, statById } from '../src/features/stats/statLifecycle.ts'

// PORT SHOP — TRUTH IN PRESENTATION.
//
// THE RULING (owner, 2026-08-04): "A dormant stat must not be represented as an effective player
// benefit," and for this surface: "A player must not spend resources on a benefit the engine does
// not apply."
//
// Every offer below is the REAL production catalog row, read off module_types with the anon key on
// 2026-08-04. A synthetic fixture would prove the predicate; only the live rows prove the ruling.
//
// Run: `npx playwright test portShopTruth.spec.ts`

const module_ = (
  ref: string,
  name: string,
  slot: string,
  stats: Record<string, number> | null,
  range: number | null = null,
  power: number | null = null,
): ShopOffer => ({
  kind: 'module',
  ref_id: ref,
  price: 100,
  name,
  slot_type: slot,
  slot_cost: 1,
  stats_json: stats,
  range,
  power,
  ammo_type: null,
  category: null,
  rarity: null,
  description: null,
})

// ── the live catalog, verbatim ──────────────────────────────────────────────────────────────────
const MINING_RIG = module_('mining_rig_extension', 'Mining Rig Extension', 'mining', { mining: 8 }, 120, 8)
const DEEP_SCAN = module_('deep_scan_sensor_array', 'Deep-Scan Sensor Array', 'sensor', { scan: 8 })
const THRUSTER = module_('vector_thruster_kit', 'Vector Thruster Kit', 'engine', {
  evasion: 3,
  speed_mult_bonus: 0.1,
})
const CARGO_LATTICE = module_('expanded_cargo_lattice', 'Expanded Cargo Lattice', 'cargo', { cargo: 25 })
const SHIELD = module_('shield_lattice', 'Shield Lattice', 'defense', { defense: 12 })
const AUTOCANNON = module_('autocannon_battery', 'Autocannon Battery', 'weapon', { attack: 10 }, 5, 10)
const AMMO: ShopOffer = {
  kind: 'item',
  ref_id: 'scrap',
  price: 4,
  name: 'Scrap',
  slot_type: null,
  slot_cost: null,
  stats_json: null,
  range: null,
  power: null,
  ammo_type: null,
  category: 'material',
  rarity: 'common',
  description: null,
}

const labels = (o: ShopOffer) => offerStatChips(o).map((c) => c.label)

// ── DORMANT IS NOT ADVERTISED ───────────────────────────────────────────────────────────────────

test('NO DORMANT STAT IS ADVERTISED AT POINT OF SALE — the named violation, on the live catalog', () => {
  // portShop.ts:49 used to read `mining: 'Mining yield'`, so the mining rig sold a "Mining yield +8"
  // that the game applies nowhere.
  expect(labels(MINING_RIG)).not.toContain('Mining Yield +8')
  for (const chip of offerStatChips(MINING_RIG)) {
    expect(chip.label.toLowerCase()).not.toContain('mining')
  }
  expect(labels(DEEP_SCAN)).toEqual([])
  expect(labels(THRUSTER)).not.toContain('Retreat Safety +3')
})

test('no chip anywhere names a dormant stat, whatever the offer claims', () => {
  const everyDormantClaim: Record<string, number> = {}
  for (const statId of DORMANT_STAT_IDS) {
    const def = statById(statId)
    if (def) everyDormantClaim[def.catalogKey] = 7
  }
  const kitchenSink = module_('probe', 'Probe', 'sensor', everyDormantClaim)
  expect(offerStatChips(kitchenSink)).toEqual([])
})

test('an UNKNOWN stats_json key fails closed — never shown, never named', () => {
  const weird = module_('probe', 'Probe', 'sensor', { luck: 5, morale: -3, __proto__: 9 })
  expect(offerStatChips(weird)).toEqual([])
  // and an offer whose ONLY claims are unknown is treated exactly like a purely dormant one
  expect(offerEffectStanding(weird)).toBe('no_live_effect')
})

// ── ACTIVE STATS STAY VISIBLE ───────────────────────────────────────────────────────────────────

test('ACTIVE stat chips survive untouched, under the registry display names', () => {
  expect(labels(SHIELD)).toEqual(['Survival +12'])
  expect(labels(AUTOCANNON)).toEqual(['Combat Power +10', 'Range 5', 'Power 10'])
  // the thruster keeps its live speed bonus, as a percent of hull base speed (0111)
  expect(labels(THRUSTER)).toEqual(['Speed +10%'])
  for (const chip of offerStatChips(SHIELD)) expect(chip.standing).toBe('effective')
})

test('a module keeps its dormant chip hidden WITHOUT losing its other attributes', () => {
  // mining_rig_extension: mining 8 is dormant, but range 120 is READ (mining_extract takes the
  // radius from max(mt.range) over fitted mining modules, 0229:309-321, and
  // module_range_attributes_enabled is TRUE in production). Rule 2: never withdraw a module that
  // has another live effect.
  expect(labels(MINING_RIG)).toEqual(['Range 120', 'Power 8'])
  expect(offerEffectStanding(MINING_RIG)).toBe('ok')
})

// ── DEPRECATED IS SHOWN, AND MARKED ─────────────────────────────────────────────────────────────

test('a DEPRECATED stat is still shown for its existing reader, marked legacy, never as a new effect', () => {
  const chips = offerStatChips(CARGO_LATTICE)
  expect(chips).toHaveLength(1)
  expect(chips[0].standing).toBe('legacy')
  expect(chips[0].label).toContain('25')
  // the registry's own name says legacy out loud — nothing here invents the word
  expect(chips[0].label).toContain('legacy')
  // and it is NOT treated as a dead offer: a legacy effect is a real (if non-authoritative) reader
  expect(offerEffectStanding(CARGO_LATTICE)).toBe('ok')
})

// ── AVAILABILITY: THE NARROWEST TRUTHFUL TREATMENT ──────────────────────────────────────────────

test('the ONLY live offer whose every claimed effect is dormant is marked not-implemented', () => {
  // deep_scan_sensor_array: stats_json {"scan": 8} → `scouting`, dormant; range and power explicitly
  // NULL (0229:134); and it changes no scan radius — every scan reads the flat cfg key
  // exploration_scan_radius (0099:176) and no module contributes to it.
  expect(offerEffectStanding(DEEP_SCAN)).toBe('no_live_effect')
  // …and it is the only one on the live catalog.
  for (const live of [MINING_RIG, THRUSTER, CARGO_LATTICE, SHIELD, AUTOCANNON, AMMO]) {
    expect(offerEffectStanding(live), `${live.ref_id} must stay on sale`).toBe('ok')
  }
})

test('an offer that claims NO stat effect at all is never marked', () => {
  // Ammo and plain items carry no stats_json. Marking them would be inventing a defect.
  expect(offerEffectStanding(AMMO)).toBe('ok')
  expect(offerEffectStanding(module_('x', 'X', 'weapon', null))).toBe('ok')
  expect(offerEffectStanding(module_('x', 'X', 'weapon', {}))).toBe('ok')
  // a zero-valued claim is no claim (a 0 effect is no effect — the shipTraits idiom)
  expect(offerEffectStanding(module_('x', 'X', 'sensor', { scan: 0 }))).toBe('ok')
})

test('the not-implemented line is plain product language, with no jargon and no schema key', () => {
  expect(NO_LIVE_EFFECT_NOTE).toBe('Not currently implemented — this does nothing in the game yet.')
  expect(NO_LIVE_EFFECT_NOTE).not.toContain('dormant')
  expect(NO_LIVE_EFFECT_NOTE).not.toContain('stat')
  expect(NO_LIVE_EFFECT_NOTE).not.toContain('_')
})

// ── WHAT THIS SLICE MUST NOT DO ─────────────────────────────────────────────────────────────────

test('nothing here activates mining, invents behaviour, or touches price/ownership', () => {
  // The chips are a pure projection of the offer the server sent: same price, same ref, no writes.
  const before = JSON.stringify(MINING_RIG)
  offerStatChips(MINING_RIG)
  offerEffectStanding(MINING_RIG)
  expect(JSON.stringify(MINING_RIG)).toBe(before)
})

test('the buy MIRROR of the server reject order is untouched by this change', () => {
  // buyAvailability stays the 0235 mirror and knows nothing about lifecycle — the two questions are
  // composed in ShopPanel, never merged. A client-only verdict inside the server mirror would be a
  // second authority on "may I buy this".
  const source = offerEffectStanding.toString()
  expect(source).not.toContain('BuyReason')
  expect(source).not.toContain('port_shop_disabled')
})

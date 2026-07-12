import { test, expect } from '@playwright/test'
import {
  CATEGORY_TONE,
  getItemGlyph,
  itemLabel,
  titleCaseId,
  ITEM_TYPE_IDS,
  TRADE_GOOD_IDS,
  MODULE_TYPE_IDS,
  RESOURCE_IDS,
  type ItemKind,
} from '../src/components/items/itemGlyphs'

// ITEM-VIZ — pure unit proof for the item-visual catalog (the uiPrimitives.spec.ts mold):
// TOTALITY over the REAL seeded catalogs (item_types 0039+0097, trade_goods 0073, module_types
// 0107+0183, base resources), the id→glyph/label contract, the honest unknown-id fallback, and
// the token-only category tone map. Run: `npx playwright test itemViz.spec.ts`.

const CATALOG: readonly [ItemKind, readonly string[]][] = [
  ['item', ITEM_TYPE_IDS],
  ['good', TRADE_GOOD_IDS],
  ['module', MODULE_TYPE_IDS],
  ['resource', RESOURCE_IDS],
]

test('the hardcoded catalogs match the migrations (counts + spot ids)', () => {
  // HONEST SCOPE: these counts are drift-guards against accidental ID-ARRAY edits ONLY — they
  // cannot detect a NEW migration seeding rows this file hasn't learned (0183 proved it: two
  // module_types landed on main before MODULE_TYPE_IDS knew them). The totality tests below are
  // the real force; when a seed migration lands, extend itemGlyphs.ts and bump these counts.
  expect(ITEM_TYPE_IDS.length).toBe(12) // 0039's 10 + 0097's 2
  expect(TRADE_GOOD_IDS.length).toBe(6) // 0073
  expect(MODULE_TYPE_IDS.length).toBe(6) // 0107's 4 + 0183's 2
  expect(ITEM_TYPE_IDS).toContain('pirate_alloy')
  expect(ITEM_TYPE_IDS).toContain('anomaly_shard')
  expect(TRADE_GOOD_IDS).toContain('luxury_goods')
  expect(MODULE_TYPE_IDS).toContain('deep_scan_sensor_array')
  expect(MODULE_TYPE_IDS).toContain('shield_lattice')
  expect(MODULE_TYPE_IDS).toContain('mining_rig_extension')
  expect(RESOURCE_IDS).toContain('metal')
})

test('TOTALITY: every catalog id resolves to a known glyph with valid stroked path data', () => {
  for (const [kind, ids] of CATALOG) {
    for (const id of ids) {
      const v = getItemGlyph(id, kind)
      expect(v.known, `${kind}:${id} must be a known subject`).toBe(true)
      expect(v.paths.length, `${kind}:${id} has no paths`).toBeGreaterThan(0)
      for (const p of v.paths) {
        // Valid path data: starts with a moveto command (the icons.ts contract).
        expect(p.d, `${kind}:${id} has a malformed path`).toMatch(/^[Mm]/)
      }
      expect(v.category, `${kind}:${id} must not fall back to unknown`).not.toBe('unknown')
    }
  }
})

test('TOTALITY: every catalog id has a humanized label (no raw snake_case leaks)', () => {
  for (const [kind, ids] of CATALOG) {
    for (const id of ids) {
      const label = itemLabel(id, kind)
      expect(label.length, `${kind}:${id} label empty`).toBeGreaterThan(0)
      expect(label, `${kind}:${id} label leaks an underscore`).not.toContain('_')
      expect(label[0], `${kind}:${id} label not capitalized`).toMatch(/[A-Z]/)
    }
  }
})

test('labels are the real seeded display names', () => {
  expect(itemLabel('pirate_alloy')).toBe('Pirate Alloy')
  expect(itemLabel('captain_memory_shard')).toBe('Captain Memory Shard')
  expect(itemLabel('scan_data')).toBe('Scan Data')
  expect(itemLabel('luxury_goods', 'good')).toBe('Luxury Goods')
  expect(itemLabel('autocannon_battery', 'module')).toBe('Autocannon Battery')
  expect(itemLabel('deep_scan_sensor_array', 'module')).toBe('Deep-Scan Sensor Array') // 0107's hyphen
  expect(itemLabel('shield_lattice', 'module')).toBe('Shield Lattice') // 0183
  expect(itemLabel('mining_rig_extension', 'module')).toBe('Mining Rig Extension') // 0183
  expect(itemLabel('metal', 'resource')).toBe('Metal')
})

test("the 'ore' namespace collision resolves honestly by kind (item 'Ore' vs 0073's 'Raw Ore')", () => {
  expect(itemLabel('ore')).toBe('Ore') // default order prefers item_types
  expect(itemLabel('ore', 'item')).toBe('Ore')
  expect(itemLabel('ore', 'good')).toBe('Raw Ore')
  // one rock glyph for both namespaces — same subject, same silhouette
  expect(getItemGlyph('ore', 'good').paths).toEqual(getItemGlyph('ore', 'item').paths)
  expect(getItemGlyph('ore', 'good').category).toBe('good')
  expect(getItemGlyph('ore', 'item').category).toBe('material')
})

test('distinctive silhouettes: no two subjects share a glyph (except the deliberate ore share)', () => {
  const seen = new Map<string, string>()
  for (const [kind, ids] of CATALOG) {
    for (const id of ids) {
      const key = JSON.stringify(getItemGlyph(id, kind).paths)
      const prior = seen.get(key)
      if (prior !== undefined) {
        expect(`${prior}`, `glyph shared between ${prior} and ${kind}:${id}`).toBe(`item:ore`)
        expect(`${kind}:${id}`).toBe('good:ore')
      } else {
        seen.set(key, `${kind}:${id}`)
      }
    }
  }
})

test('unknown ids degrade honestly: generic glyph, never a crash, title-case label', () => {
  const v = getItemGlyph('warp_coil')
  expect(v.known).toBe(false)
  expect(v.category).toBe('unknown')
  expect(v.paths.length).toBeGreaterThan(0)
  for (const p of v.paths) expect(p.d).toMatch(/^[Mm]/)
  expect(itemLabel('warp_coil')).toBe('Warp Coil')
  expect(titleCaseId('anti_matter_pod')).toBe('Anti Matter Pod')
  // the fallback glyph is deliberately unlike every real subject
  const fallbackKey = JSON.stringify(v.paths)
  for (const [kind, ids] of CATALOG) {
    for (const id of ids) {
      expect(JSON.stringify(getItemGlyph(id, kind).paths), `${kind}:${id} equals the fallback glyph`).not.toBe(fallbackKey)
    }
  }
})

test('unknown ids in a STATED namespace wear that namespace tone; unstated stays unknown', () => {
  expect(getItemGlyph('mystery_cargo', 'good').category).toBe('good')
  expect(getItemGlyph('mystery_module', 'module').category).toBe('module')
  expect(getItemGlyph('mystery_fuel', 'resource').category).toBe('resource')
  expect(getItemGlyph('mystery_item', 'item').category).toBe('unknown') // item categories vary — honest
  expect(getItemGlyph('mystery', undefined).category).toBe('unknown')
})

test('category tone map: token utilities only (no raw colors), the ordered ITEM-VIZ mapping', () => {
  for (const [category, tone] of Object.entries(CATEGORY_TONE)) {
    for (const cls of [tone.text, tone.tile]) {
      expect(cls, `${category} tone empty`).toBeTruthy()
      // token utilities only — never hex/rgb/named-palette literals (the design-system law)
      expect(cls, `${category} tone carries a raw color`).not.toMatch(/#|rgb|slate-|gray-|cyan-|amber-|emerald-|red-/)
      expect(cls).toMatch(/(text|bg)-(ink|accent|success|warning|danger|surface)/)
    }
  }
  // the ordered ITEM-VIZ tone decisions: materials muted · parts/data/modules accent ·
  // progression warning · goods success
  expect(CATEGORY_TONE.material.text).toBe('text-ink-muted')
  expect(CATEGORY_TONE.component.text).toBe('text-accent')
  expect(CATEGORY_TONE.data.text).toBe('text-accent')
  expect(CATEGORY_TONE.module.text).toBe('text-accent')
  expect(CATEGORY_TONE.progression.text).toBe('text-warning')
  expect(CATEGORY_TONE.good.text).toBe('text-success')
})

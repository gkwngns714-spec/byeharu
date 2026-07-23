import { test, expect } from '@playwright/test'
import {
  filterVisibleItems,
  statusFilteredByLayer,
  itemPassesStatus,
  DEFAULT_WORLD_ENTITY_STATUS_FILTER,
  WORLD_ENTITY_STATUS_FILTERS,
  WORLD_ENTITY_STATUS_LABELS,
  type WorldEntityStatusFilter,
  type WorldEditorFilterState,
} from '../src/features/worldeditor/worldEditorFilters'
import type { LayerId, LayerItem } from '../src/features/worldeditor/worldEditorTypes'

// WORLD EDITOR V5 LIFECYCLE — pure proofs for the ONE shared lifecycle VIEW filter (worldEditorFilters).
// No browser/DB: filterVisibleItems / statusFilteredByLayer / itemPassesStatus are pure. The filter is
// now cross-domain: EVERY item (from the 0269 catalog) carries a normalized lifecycle status
// ('active'|'inactive') — locations, mining, exploration AND zones — and ONE narrow honors it
// everywhere. Run: `npx playwright test worldEditorFilters.spec.ts`.

const item = (layer: LayerId, id: string, status: 'active' | 'inactive'): LayerItem => ({
  layer,
  id,
  label: id,
  representation:
    layer === 'zones'
      ? { kind: 'polygon', ring: [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 5, y: 10 }] }
      : { kind: 'point', world: { x: 0, y: 0 } },
  tone: 'var(--color-accent)',
  glyph: 'circle',
  status,
})

/** A world with a mix of active + inactive entities in EVERY domain, in registry order. */
const makeItemsByLayer = (): Map<LayerId, LayerItem[]> =>
  new Map<LayerId, LayerItem[]>([
    ['locations', [item('locations', 'loc-a', 'active'), item('locations', 'loc-i', 'inactive')]],
    ['mining', [item('mining', 'mine-a', 'active'), item('mining', 'mine-i', 'inactive')]],
    ['exploration', [item('exploration', 'exp-a', 'active'), item('exploration', 'exp-i', 'inactive')]],
    ['zones', [item('zones', 'zone-a', 'active'), item('zones', 'zone-i', 'inactive')]],
  ])

const allLayers: ReadonlySet<LayerId> = new Set<LayerId>(['locations', 'mining', 'exploration', 'zones'])
const state = (
  visibleLayers: ReadonlySet<LayerId>,
  status: WorldEntityStatusFilter,
): WorldEditorFilterState => ({ visibleLayers, status })
const ids = (items: LayerItem[]): string[] => items.map((it) => it.id)

// ── the filter vocabulary ─────────────────────────────────────────────────────────────────────────
test('the shared filter defaults to active; options are active → inactive → all', () => {
  expect(DEFAULT_WORLD_ENTITY_STATUS_FILTER).toBe('active')
  expect(WORLD_ENTITY_STATUS_FILTERS).toEqual(['active', 'inactive', 'all'])
  expect(WORLD_ENTITY_STATUS_LABELS).toEqual({ active: 'Active', inactive: 'Inactive', all: 'All' })
})

// ── all four domains under active / inactive / all ──────────────────────────────────────────────────
test('active shows only active across ALL four domains', () => {
  const out = filterVisibleItems(makeItemsByLayer(), state(allLayers, 'active'))
  expect(ids(out)).toEqual(['loc-a', 'mine-a', 'exp-a', 'zone-a'])
})

test('inactive shows only inactive across ALL four domains', () => {
  const out = filterVisibleItems(makeItemsByLayer(), state(allLayers, 'inactive'))
  expect(ids(out)).toEqual(['loc-i', 'mine-i', 'exp-i', 'zone-i'])
})

test('all shows both active and inactive across ALL four domains, in registry order', () => {
  const out = filterVisibleItems(makeItemsByLayer(), state(allLayers, 'all'))
  expect(ids(out)).toEqual(['loc-a', 'loc-i', 'mine-a', 'mine-i', 'exp-a', 'exp-i', 'zone-a', 'zone-i'])
})

// ── layer visibility composes with the lifecycle narrow ─────────────────────────────────────────────
test('a de-selected domain is hidden; the lifecycle narrow still applies to the rest', () => {
  const items = makeItemsByLayer()
  const out = filterVisibleItems(items, state(new Set<LayerId>(['mining', 'zones']), 'inactive'))
  expect(ids(out)).toEqual(['mine-i', 'zone-i'])
})

test('empty visible-set → empty view regardless of lifecycle', () => {
  for (const s of WORLD_ENTITY_STATUS_FILTERS) {
    expect(filterVisibleItems(makeItemsByLayer(), state(new Set<LayerId>(), s))).toEqual([])
  }
})

// ── statusFilteredByLayer (drives per-layer counts + the search index) ──────────────────────────────
test('statusFilteredByLayer keeps every layer key and filters by lifecycle only', () => {
  const filtered = statusFilteredByLayer(makeItemsByLayer(), 'inactive')
  expect([...filtered.keys()]).toEqual(['locations', 'mining', 'exploration', 'zones'])
  expect(ids(filtered.get('locations')!)).toEqual(['loc-i'])
  expect(ids(filtered.get('zones')!)).toEqual(['zone-i'])
  const all = statusFilteredByLayer(makeItemsByLayer(), 'all')
  expect(all.get('mining')!.length).toBe(2)
})

// ── itemPassesStatus ────────────────────────────────────────────────────────────────────────────────
test('itemPassesStatus: all passes everything; a value matches its own lifecycle only', () => {
  expect(itemPassesStatus(item('locations', 'x', 'inactive'), 'all')).toBe(true)
  expect(itemPassesStatus(item('locations', 'x', 'active'), 'active')).toBe(true)
  expect(itemPassesStatus(item('locations', 'x', 'active'), 'inactive')).toBe(false)
  expect(itemPassesStatus(item('zones', 'z', 'inactive'), 'inactive')).toBe(true)
})

// ── purity ──────────────────────────────────────────────────────────────────────────────────────────
const deepFreeze = <T>(v: T): T => {
  if (v && typeof v === 'object') {
    for (const k of Object.getOwnPropertyNames(v)) deepFreeze((v as Record<string, unknown>)[k])
    Object.freeze(v)
  }
  return v
}

test('filterVisibleItems / statusFilteredByLayer NEVER mutate their input', () => {
  const items = makeItemsByLayer()
  const snapshot = JSON.parse(JSON.stringify([...items.entries()])) as unknown
  for (const list of items.values()) deepFreeze(list)
  deepFreeze(items)
  for (const s of WORLD_ENTITY_STATUS_FILTERS) {
    expect(() => filterVisibleItems(items, state(allLayers, s))).not.toThrow()
    expect(() => statusFilteredByLayer(items, s)).not.toThrow()
  }
  expect(JSON.parse(JSON.stringify([...items.entries()]))).toEqual(snapshot)
})

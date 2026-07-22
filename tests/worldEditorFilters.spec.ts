import { test, expect } from '@playwright/test'
import {
  filterVisibleItems,
  itemPassesStatus,
  DEFAULT_STATUS_FILTER,
  STATUS_FILTER_ALL,
  STATUS_FILTER_OPTIONS,
  type StatusFilter,
  type WorldEditorFilterState,
} from '../src/features/worldeditor/worldEditorFilters'
import { LOCATION_STATUSES } from '../src/features/worldeditor/locationEnums'
import type { LayerId, LayerItem } from '../src/features/worldeditor/worldEditorTypes'

// WORLD EDITOR V5 — pure proofs for the layer/status VIEW filter (worldEditorFilters). No browser/DB:
// filterVisibleItems is pure (items + filter state in → filtered LayerItem[] out). It composes the
// existing layer-visibility set with the new status narrow and MUST reproduce the shell's former
// flatten exactly under the default state. Run: `npx playwright test worldEditorFilters.spec.ts`.

const location = (id: string, status: string): LayerItem => ({
  layer: 'locations',
  id,
  label: id,
  representation: { kind: 'point', world: { x: 0, y: 0 } },
  tone: 'var(--color-accent)',
  glyph: 'circle',
  status,
})

// mining/exploration/zones carry NO status in their read contract → LayerItem.status stays undefined.
const point = (layer: LayerId, id: string): LayerItem => ({
  layer,
  id,
  label: id,
  representation: { kind: 'point', world: { x: 100, y: 100 } },
  tone: 'var(--color-warning)',
  glyph: 'hex',
})

const zone = (id: string): LayerItem => ({
  layer: 'zones',
  id,
  label: id,
  representation: { kind: 'polygon', ring: [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 5, y: 10 }] },
  tone: 'var(--color-danger)',
  glyph: 'circle',
})

/** A world with mixed location statuses + status-less domains, in registry order. */
const makeItemsByLayer = (): Map<LayerId, LayerItem[]> =>
  new Map<LayerId, LayerItem[]>([
    ['locations', [location('port-a', 'active'), location('port-b', 'locked'), location('port-c', 'hidden')]],
    ['mining', [point('mining', 'field-1'), point('mining', 'field-2')]],
    ['exploration', [point('exploration', 'site-1')]],
    ['zones', [zone('zone-1')]],
  ])

const allLayers: ReadonlySet<LayerId> = new Set<LayerId>(['locations', 'mining', 'exploration', 'zones'])
const state = (
  visibleLayers: ReadonlySet<LayerId>,
  status: StatusFilter = STATUS_FILTER_ALL,
): WorldEditorFilterState => ({ visibleLayers, status })

const ids = (items: LayerItem[]): string[] => items.map((it) => it.id)

// ── default state == identity (today's whole-world flatten) ─────────────────────────────────────────
test('default state (all layers visible + status all) reproduces the naive registry-order flatten', () => {
  const items = makeItemsByLayer()
  // the exact flatten the shell used inline before this module existed
  const naive: LayerItem[] = []
  for (const layer of ['locations', 'mining', 'exploration', 'zones'] as LayerId[]) {
    naive.push(...(items.get(layer) ?? []))
  }
  expect(DEFAULT_STATUS_FILTER).toBe(STATUS_FILTER_ALL)
  expect(filterVisibleItems(items, state(allLayers))).toEqual(naive)
  expect(filterVisibleItems(items, state(allLayers))).toHaveLength(7)
})

// ── layer visibility ────────────────────────────────────────────────────────────────────────────────
test('a de-selected domain is hidden; only selected domains show', () => {
  const items = makeItemsByLayer()
  // hide mining + exploration + zones → locations only
  const out = filterVisibleItems(items, state(new Set<LayerId>(['locations'])))
  expect(ids(out)).toEqual(['port-a', 'port-b', 'port-c'])
  // hide locations → the status-less domains remain
  const out2 = filterVisibleItems(items, state(new Set<LayerId>(['mining', 'zones'])))
  expect(ids(out2)).toEqual(['field-1', 'field-2', 'zone-1'])
})

test('empty visible-set → empty view', () => {
  expect(filterVisibleItems(makeItemsByLayer(), state(new Set<LayerId>()))).toEqual([])
})

// ── status narrow (locations only) ──────────────────────────────────────────────────────────────────
test('status narrow includes matching locations and excludes the rest', () => {
  const items = makeItemsByLayer()
  const active = filterVisibleItems(items, state(new Set<LayerId>(['locations']), 'active'))
  expect(ids(active)).toEqual(['port-a'])
  const hidden = filterVisibleItems(items, state(new Set<LayerId>(['locations']), 'hidden'))
  expect(ids(hidden)).toEqual(['port-c'])
})

test('status narrow NEVER hides a status-less domain (undefined status always passes)', () => {
  const items = makeItemsByLayer()
  // narrow to 'locked' across ALL layers: only port-b of locations, but every mining/exploration/zone
  // item survives because they carry no status to match against.
  const out = filterVisibleItems(items, state(allLayers, 'locked'))
  expect(ids(out)).toEqual(['port-b', 'field-1', 'field-2', 'site-1', 'zone-1'])
})

test('itemPassesStatus: all passes everything; a value matches equal / undefined, excludes others', () => {
  expect(itemPassesStatus(location('x', 'locked'), STATUS_FILTER_ALL)).toBe(true)
  expect(itemPassesStatus(location('x', 'active'), 'active')).toBe(true)
  expect(itemPassesStatus(location('x', 'active'), 'hidden')).toBe(false)
  // a status-less item passes any narrow
  expect(itemPassesStatus(point('mining', 'm'), 'hidden')).toBe(true)
})

test('STATUS_FILTER_OPTIONS is "all" + every legal location status, in order', () => {
  expect(STATUS_FILTER_OPTIONS).toEqual([STATUS_FILTER_ALL, ...LOCATION_STATUSES])
})

// ── purity: stored data never mutated ───────────────────────────────────────────────────────────────
const deepFreeze = <T>(v: T): T => {
  if (v && typeof v === 'object') {
    for (const k of Object.getOwnPropertyNames(v)) deepFreeze((v as Record<string, unknown>)[k])
    Object.freeze(v)
  }
  return v
}

test('filterVisibleItems NEVER mutates its input: deep-frozen items pass through untouched', () => {
  const items = makeItemsByLayer()
  const snapshot = JSON.parse(JSON.stringify([...items.entries()])) as unknown
  for (const list of items.values()) deepFreeze(list)
  deepFreeze(items)

  for (const s of STATUS_FILTER_OPTIONS) {
    expect(() => filterVisibleItems(items, state(allLayers, s))).not.toThrow()
  }
  expect(JSON.parse(JSON.stringify([...items.entries()]))).toEqual(snapshot)
})

import { test, expect } from '@playwright/test'
import { cameraForDomain, focusPointsForDomain } from '../src/features/worldeditor/worldEditorFocus'
import { MAX_K, MIN_K, fitCameraToWorldPoints } from '../src/features/map/galaxyCamera'
import type { LayerId, LayerItem } from '../src/features/worldeditor/worldEditorTypes'

// WORLD EDITOR C1 — pure proofs for the CAMERA-ONLY domain framer (worldEditorFocus). No browser/DB:
// focusPointsForDomain / cameraForDomain are pure (data in → points / Camera out). The deep-freeze
// suite is the "stored coordinates unchanged" proof — focusing NEVER mutates any input coordinate.
// Run: `npx playwright test worldEditorFocus.spec.ts`.

const point = (layer: LayerId, id: string, x: number, y: number): LayerItem => ({
  layer,
  id,
  label: id,
  representation: { kind: 'point', world: { x, y } },
  tone: 'var(--color-accent)',
  glyph: 'circle',
})

const polygon = (layer: LayerId, id: string, ring: { x: number; y: number }[]): LayerItem => ({
  layer,
  id,
  label: id,
  representation: { kind: 'polygon', ring },
  tone: 'var(--color-danger)',
  glyph: 'circle',
})

/** A world shaped like production reality: locations tightly clustered near the origin, mining and
 *  exploration far out at their true tiers, one zone polygon. */
const makeItemsByLayer = (): Map<LayerId, LayerItem[]> =>
  new Map<LayerId, LayerItem[]>([
    ['locations', [point('locations', 'port-a', -100, -100), point('locations', 'port-b', 100, 100)]],
    ['mining', [point('mining', 'field-1', 5000, 5000), point('mining', 'field-2', 6000, 6000)]],
    ['exploration', [point('exploration', 'site-1', -8000, 8000)]],
    ['zones', [polygon('zones', 'zone-1', [{ x: 2000, y: 2000 }, { x: 2400, y: 2000 }, { x: 2200, y: 2400 }])]],
  ])

const isValidCamera = (c: { k: number; tx: number; ty: number }): boolean =>
  Number.isFinite(c.k) && Number.isFinite(c.tx) && Number.isFinite(c.ty) && c.k >= MIN_K && c.k <= MAX_K

// ── point filtering ─────────────────────────────────────────────────────────────────────────────────
test('focusPointsForDomain filters by domain; "all" collects every layer; empty layer → no points', () => {
  const items = makeItemsByLayer()

  expect(focusPointsForDomain(items, 'mining')).toEqual([
    { x: 5000, y: 5000 },
    { x: 6000, y: 6000 },
  ])
  expect(focusPointsForDomain(items, 'locations')).toEqual([
    { x: -100, y: -100 },
    { x: 100, y: 100 },
  ])
  // the zone polygon contributes its ring vertices
  expect(focusPointsForDomain(items, 'zones')).toHaveLength(3)
  // 'all' = every layer's points (2 + 2 + 1 + 3)
  expect(focusPointsForDomain(items, 'all')).toHaveLength(8)
  // an empty map frames nothing
  expect(focusPointsForDomain(new Map(), 'all')).toEqual([])
})

test('focusPointsForDomain: opts.selected pulls one cross-domain item into the frame', () => {
  const items = makeItemsByLayer()
  const pts = focusPointsForDomain(items, 'locations', { selected: { layer: 'mining', id: 'field-1' } })
  // both locations + the ONE selected mining field (not the other one)
  expect(pts).toHaveLength(3)
  expect(pts).toContainEqual({ x: 5000, y: 5000 })
  expect(pts).not.toContainEqual({ x: 6000, y: 6000 })
})

// ── camera derivation (REUSES the shared galaxyCamera fit — no second transform) ────────────────────
test('cameraForDomain frames the chosen subset: a locations-only fit differs from the all fit and matches the shared fit exactly', () => {
  const items = makeItemsByLayer()

  const all = cameraForDomain(items, 'all')
  const locations = cameraForDomain(items, 'locations')
  const mining = cameraForDomain(items, 'mining')

  for (const c of [all, locations, mining]) expect(isValidCamera(c)).toBe(true)

  // the tight locations cluster zooms far deeper than the whole-world fit
  expect(locations.k).toBeGreaterThan(all.k)
  expect(locations).not.toEqual(all)
  expect(mining).not.toEqual(all)
  expect(mining).not.toEqual(locations)

  // byte-identical to the ONE shared galaxyCamera fit over the same points (no second fit math)
  expect(locations).toEqual(fitCameraToWorldPoints(focusPointsForDomain(items, 'locations')))
  expect(all).toEqual(fitCameraToWorldPoints(focusPointsForDomain(items, 'all')))
})

test('cameraForDomain: an empty domain yields the identity camera (the shared fit empty rule)', () => {
  const items = new Map<LayerId, LayerItem[]>([['locations', []]])
  expect(cameraForDomain(items, 'mining')).toEqual({ k: 1, tx: 0, ty: 0 })
  expect(cameraForDomain(items, 'all')).toEqual({ k: 1, tx: 0, ty: 0 })
})

// ── the "stored coordinates unchanged" proof: pure, never mutates input ─────────────────────────────
const deepFreeze = <T>(v: T): T => {
  if (v && typeof v === 'object') {
    for (const k of Object.getOwnPropertyNames(v)) deepFreeze((v as Record<string, unknown>)[k])
    Object.freeze(v)
  }
  return v
}

test('focus helpers NEVER mutate the input data: deep-frozen items pass through untouched (no throw, unchanged)', () => {
  const items = makeItemsByLayer()
  const snapshot = JSON.parse(JSON.stringify([...items.entries()])) as unknown
  for (const list of items.values()) deepFreeze(list)
  deepFreeze(items)

  // every call path over frozen input: no throw = zero writes to any coordinate anywhere
  for (const domain of ['all', 'locations', 'mining', 'exploration', 'zones'] as const) {
    expect(() => focusPointsForDomain(items, domain)).not.toThrow()
    expect(() => cameraForDomain(items, domain)).not.toThrow()
  }
  expect(() =>
    cameraForDomain(items, 'locations', { selected: { layer: 'zones', id: 'zone-1' } }),
  ).not.toThrow()

  // and the data is byte-identical afterwards — stored coordinates unchanged
  expect(JSON.parse(JSON.stringify([...items.entries()]))).toEqual(snapshot)
})

test('determinism: same input → deep-equal points and camera on repeat calls', () => {
  const a = makeItemsByLayer()
  const b = makeItemsByLayer()
  expect(focusPointsForDomain(a, 'all')).toEqual(focusPointsForDomain(b, 'all'))
  expect(cameraForDomain(a, 'exploration')).toEqual(cameraForDomain(b, 'exploration'))
})

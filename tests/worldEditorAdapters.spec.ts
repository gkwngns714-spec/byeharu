import { test, expect } from '@playwright/test'
import {
  locationLayerAdapter,
  miningLayerAdapter,
  explorationLayerAdapter,
  zoneLayerAdapter,
} from '../src/features/worldeditor/worldEditorAdapters'
import {
  WORLD_EDITOR_LAYERS,
  defaultVisibleLayerIds,
} from '../src/features/worldeditor/worldEditorRegistry'
import {
  DEFERRED_OPERATIONS,
  type ReadOnlyLayerAdapter,
} from '../src/features/worldeditor/worldEditorTypes'
import type { WorldEditorData } from '../src/features/worldeditor/worldEditorData'
import type { MapLocation } from '../src/features/map/mapTypes'

// WORLD EDITOR V1 — pure proofs for the four read-only layer adapters + registry. No browser/DB: the
// adapters are pure (rows in → typed items/fields out). Run: `npx playwright test worldEditorAdapters.spec.ts`.

const loc = (over: Partial<MapLocation> = {}): MapLocation => ({
  id: 'loc-1',
  name: 'Aurelia Port',
  location_type: 'trade_outpost',
  x: 120,
  y: -80,
  base_difficulty: 5,
  reward_tier: 3,
  activity_type: 'trade_visit',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  territory_radius: 400,
  ...over,
})

const DATA: WorldEditorData = {
  locations: [loc(), loc({ id: 'loc-2', name: 'Reef Den', location_type: 'pirate_den', x: -50, y: 200 })],
  zoneRefs: [{ zone_id: 'zone-1', zone_name: 'Wreck Belt', sector_name: 'Outer Haven' }],
  miningFields: [{ name: 'Sparse Ore Belt', space_x: 300, space_y: 150 }],
  explorationSites: [{ name: 'Signal 7', space_x: -400, space_y: 620 }],
  zones: [
    { id: 'z-drawn', name: 'Crimson Reach', source: 'drawn', location_id: 'loc-2', ring: [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]] },
    { id: 'z-circle', name: 'Seeded Ring', source: 'circle', location_id: null, ring: [[5, 5], [6, 5], [6, 6], [5, 5]] },
    { id: 'z-bad', name: 'Too Few', source: 'drawn', location_id: null, ring: [[1, 1], [2, 2]] }, // < 3 → skipped
  ],
}

// ── Locations layer ─────────────────────────────────────────────────────────────────────────────────
test('locations: point representation at canonical world x/y + token tone', () => {
  const items = locationLayerAdapter.readItems(DATA)
  expect(items).toHaveLength(2)
  const port = items[0]
  expect(port.layer).toBe('locations')
  expect(port.id).toBe('loc-1')
  expect(port.representation).toEqual({ kind: 'point', world: { x: 120, y: -80 } })
  expect(port.tone.startsWith('var(--color-')).toBe(true) // token ref, never a raw literal
  expect(['circle', 'diamond', 'triangle', 'hex']).toContain(port.glyph)
})

test('locations: inspect exposes typed fields + canonical coords; unknown id → null', () => {
  const fields = locationLayerAdapter.inspect(DATA, 'loc-1')
  expect(fields).not.toBeNull()
  const byLabel = Object.fromEntries(fields!.map((f) => [f.label, f.value]))
  expect(byLabel['Location type']).toBe('trade_outpost')
  expect(byLabel['World X']).toBe('120.0')
  expect(byLabel['World Y']).toBe('-80.0')
  expect(locationLayerAdapter.inspect(DATA, 'nope')).toBeNull()
})

// ── Mining layer ─────────────────────────────────────────────────────────────────────────────────────
test('mining: hex glyph at space_x/space_y; inspect never leaks the reward bundle composition', () => {
  const items = miningLayerAdapter.readItems(DATA)
  expect(items).toHaveLength(1)
  expect(items[0].glyph).toBe('hex')
  expect(items[0].representation).toEqual({ kind: 'point', world: { x: 300, y: 150 } })
  const fields = miningLayerAdapter.inspect(DATA, 'Sparse Ore Belt')!
  const byLabel = Object.fromEntries(fields.map((f) => [f.label, f.value]))
  expect(byLabel['World X']).toBe('300.0')
  expect(byLabel['Reward bundle']).toMatch(/server-revealed/)
  expect(miningLayerAdapter.inspect(DATA, 'nope')).toBeNull()
})

// ── Exploration layer ─────────────────────────────────────────────────────────────────────────────────
test('exploration: diamond glyph at space_x/space_y; inspect returns typed coords', () => {
  const items = explorationLayerAdapter.readItems(DATA)
  expect(items).toHaveLength(1)
  expect(items[0].glyph).toBe('diamond')
  expect(items[0].representation).toEqual({ kind: 'point', world: { x: -400, y: 620 } })
  expect(explorationLayerAdapter.inspect(DATA, 'Signal 7')).not.toBeNull()
})

// ── Zones layer ─────────────────────────────────────────────────────────────────────────────────────
test('zones: polygon representation; rings < 3 vertices are skipped; source drives the tone', () => {
  const items = zoneLayerAdapter.readItems(DATA)
  expect(items.map((i) => i.id)).toEqual(['z-drawn', 'z-circle']) // z-bad skipped
  const drawn = items.find((i) => i.id === 'z-drawn')!
  expect(drawn.representation.kind).toBe('polygon')
  expect(drawn.tone).toBe('var(--color-warning)')
  const circle = items.find((i) => i.id === 'z-circle')!
  expect(circle.tone).toBe('var(--color-danger)')
})

test('zones: inspect reports source + boundary attachment', () => {
  const fields = zoneLayerAdapter.inspect(DATA, 'z-drawn')!
  const byLabel = Object.fromEntries(fields.map((f) => [f.label, f.value]))
  expect(byLabel['Source']).toBe('drawn')
  expect(byLabel['Boundary']).toBe('attached to a location')
  const standalone = zoneLayerAdapter.inspect(DATA, 'z-circle')!
  expect(Object.fromEntries(standalone.map((f) => [f.label, f.value]))['Boundary']).toBe('standalone')
})

// ── READ-ONLY guarantee: the adapters expose read/resolve/inspect ONLY, no mutation seam ─────────────
test('adapters are strictly read-only — no create/edit/publish/enable/disable/archive method exists', () => {
  const adapters: ReadOnlyLayerAdapter<WorldEditorData>[] = [
    locationLayerAdapter,
    miningLayerAdapter,
    explorationLayerAdapter,
    zoneLayerAdapter,
  ]
  const forbidden = ['create', 'edit', 'publish', 'enable', 'disable', 'archive', 'save', 'update', 'delete', 'mutate']
  for (const a of adapters) {
    expect(Object.keys(a).sort()).toEqual(['id', 'inspect', 'readItems', 'title'])
    for (const op of forbidden) expect(op in a).toBe(false)
  }
  // The deferred authoring ops are declared for explicit-disable UI, not as adapter methods.
  expect([...DEFERRED_OPERATIONS].sort()).toEqual(['archive', 'create', 'disable', 'edit', 'enable', 'publish'])
})

// ── Registry ─────────────────────────────────────────────────────────────────────────────────────────
test('registry lists the four layers in order, all visible by default', () => {
  expect(WORLD_EDITOR_LAYERS.map((e) => e.adapter.id)).toEqual(['locations', 'mining', 'exploration', 'zones'])
  expect(WORLD_EDITOR_LAYERS.every((e) => e.defaultVisible)).toBe(true)
  expect([...defaultVisibleLayerIds()].sort()).toEqual(['exploration', 'locations', 'mining', 'zones'])
})

import { test, expect } from '@playwright/test'
import {
  normalizeCatalogRow,
  normalizeCatalogRows,
  catalogDomainToLayer,
  catalogRowSelectionId,
  catalogRowToLayerItem,
  catalogItemsByLayer,
  findCatalogRow,
  catalogRowPassesStatus,
  type WorldEditorCatalogRow,
} from '../src/features/worldeditor/worldEditorCatalog'
import { representationWorldPoints } from '../src/features/worldeditor/worldEditorGeometry'
import { filterVisibleItems } from '../src/features/worldeditor/worldEditorFilters'
import { fitCameraToWorldPoints } from '../src/features/map/galaxyCamera'
import { markerStyle } from '../src/features/map/markerStyle'
import type { LayerId } from '../src/features/worldeditor/worldEditorTypes'

// WORLD EDITOR V5 LIFECYCLE — pure proofs for the 0269 catalog model (worldEditorCatalog). No browser/
// DB: normalization (untrusted jsonb → typed rows), the domain↔layer bridge, the per-row selection id,
// and the row→LayerItem projection are all pure. Run: `npx playwright test worldEditorCatalog.spec.ts`.

// Raw server rows (the exact 0269 row contract): revision null for every row; updated_at non-null only
// for zones; point is the anchor/centroid; geometry is the closed vertex ring (zones only).
const rawLocation = (
  id: string,
  name: string,
  lifecycle: string,
  marker: { location_type?: string | null; activity_type?: string | null; reward_tier?: number | null; base_difficulty?: number | null } = {},
) => ({
  domain: 'location', entity_id: id, name, lifecycle_status: lifecycle,
  revision: null, point: { x: -100, y: 200 }, geometry: null, updated_at: null,
  // 0271 marker-style fields (location-only); defaults to a plain safe_zone waypoint.
  location_type: marker.location_type === undefined ? 'safe_zone' : marker.location_type,
  activity_type: marker.activity_type === undefined ? 'none' : marker.activity_type,
  reward_tier: marker.reward_tier === undefined ? 0 : marker.reward_tier,
  base_difficulty: marker.base_difficulty === undefined ? 0 : marker.base_difficulty,
})
const rawMining = (id: string, name: string, lifecycle: string) => ({
  domain: 'mining', entity_id: id, name, lifecycle_status: lifecycle,
  revision: null, point: { x: 5000, y: -5000 }, geometry: null, updated_at: null,
})
const rawExploration = (id: string, name: string, lifecycle: string) => ({
  domain: 'exploration', entity_id: id, name, lifecycle_status: lifecycle,
  revision: null, point: { x: 10, y: 20 }, geometry: null, updated_at: null,
})
const rawZone = (id: string, name: string, lifecycle: string) => ({
  domain: 'zone', entity_id: id, name, lifecycle_status: lifecycle, revision: null,
  point: { x: 2200, y: 2130 },
  geometry: { kind: 'ring', ring: [[2000, 2000], [2400, 2000], [2200, 2400], [2000, 2000]] },
  updated_at: '2026-07-20T00:00:00Z',
})

// ── normalization ────────────────────────────────────────────────────────────────────────────────────
test('normalizeCatalogRow parses each domain, keeps null revision + null/typed updated_at', () => {
  const loc = normalizeCatalogRow(rawLocation('loc-1', 'Porthaven', 'active'))!
  expect(loc).toMatchObject({ domain: 'location', entityId: 'loc-1', name: 'Porthaven', lifecycleStatus: 'active' })
  expect(loc.revision).toBeNull()
  expect(loc.updatedAt).toBeNull()
  expect(loc.point).toEqual({ x: -100, y: 200 })
  expect(loc.geometry).toBeNull()

  const zone = normalizeCatalogRow(rawZone('z-1', 'Reach', 'inactive'))!
  expect(zone.domain).toBe('zone')
  expect(zone.geometry?.kind).toBe('ring')
  expect(zone.geometry?.ring).toHaveLength(4)
  expect(zone.updatedAt).toBe('2026-07-20T00:00:00Z')
})

test('normalizeCatalogRow drops malformed rows (unknown domain, bad lifecycle, missing id/name)', () => {
  expect(normalizeCatalogRow({ domain: 'planet', entity_id: 'x', name: 'y', lifecycle_status: 'active' })).toBeNull()
  expect(normalizeCatalogRow({ domain: 'zone', entity_id: 'x', name: 'y', lifecycle_status: 'archived' })).toBeNull()
  expect(normalizeCatalogRow({ domain: 'location', entity_id: '', name: 'y', lifecycle_status: 'active' })).toBeNull()
  expect(normalizeCatalogRow({ domain: 'location', entity_id: 'x', lifecycle_status: 'active' })).toBeNull()
  expect(normalizeCatalogRow(null)).toBeNull()
  expect(normalizeCatalogRow('nope')).toBeNull()
})

test('normalizeCatalogRows reads the {rows:[...]} envelope and drops bad rows fail-closed', () => {
  const rows = normalizeCatalogRows({
    ok: true,
    status: 'all',
    rows: [rawLocation('l', 'A', 'active'), { junk: true }, rawZone('z', 'B', 'inactive')],
  })
  expect(rows.map((r) => r.entityId)).toEqual(['l', 'z'])
  // a non-envelope / missing rows → empty (never throws into render)
  expect(normalizeCatalogRows(null)).toEqual([])
  expect(normalizeCatalogRows({ ok: false, error: 'not_authorized' })).toEqual([])
})

// ── domain ↔ layer, selection id ──────────────────────────────────────────────────────────────────
test('catalogDomainToLayer maps the singular server tag to the plural LayerId', () => {
  expect(catalogDomainToLayer('location')).toBe('locations')
  expect(catalogDomainToLayer('zone')).toBe('zones')
  expect(catalogDomainToLayer('mining')).toBe('mining')
  expect(catalogDomainToLayer('exploration')).toBe('exploration')
})

test('catalogRowSelectionId is the NAME for mining/exploration and the UUID for location/zone', () => {
  expect(catalogRowSelectionId(normalizeCatalogRow(rawMining('m-uuid', 'Iron Belt', 'active'))!)).toBe('Iron Belt')
  expect(catalogRowSelectionId(normalizeCatalogRow(rawExploration('e-uuid', 'Nebula', 'active'))!)).toBe('Nebula')
  expect(catalogRowSelectionId(normalizeCatalogRow(rawLocation('loc-uuid', 'Porthaven', 'active'))!)).toBe('loc-uuid')
  expect(catalogRowSelectionId(normalizeCatalogRow(rawZone('zone-uuid', 'Reach', 'active'))!)).toBe('zone-uuid')
})

// ── row → LayerItem ──────────────────────────────────────────────────────────────────────────────────
test('catalogRowToLayerItem carries lifecycle status + dims inactive; zones become polygons', () => {
  const activeMine = catalogRowToLayerItem(normalizeCatalogRow(rawMining('m', 'Iron Belt', 'active'))!)!
  expect(activeMine).toMatchObject({ layer: 'mining', id: 'Iron Belt', label: 'Iron Belt', glyph: 'hex', status: 'active' })
  expect(activeMine.representation).toEqual({ kind: 'point', world: { x: 5000, y: -5000 } })
  expect(activeMine.tone).toBe('var(--color-warning)')

  const inactiveMine = catalogRowToLayerItem(normalizeCatalogRow(rawMining('m2', 'Cold Belt', 'inactive'))!)!
  expect(inactiveMine.status).toBe('inactive')
  expect(inactiveMine.tone).toBe('var(--color-ink-faint)') // dimmed

  const zone = catalogRowToLayerItem(normalizeCatalogRow(rawZone('z', 'Reach', 'inactive'))!)!
  expect(zone.representation.kind).toBe('polygon')
  expect(zone.status).toBe('inactive')
})

// ── itemsByLayer grouping + registry-order keys ──────────────────────────────────────────────────────
test('catalogItemsByLayer groups rows by layer and always keeps all four registry keys', () => {
  const rows = normalizeCatalogRows({
    rows: [
      rawLocation('l1', 'A', 'active'),
      rawMining('m1', 'Belt', 'inactive'),
      rawZone('z1', 'Reach', 'active'),
    ],
  })
  const map = catalogItemsByLayer(rows)
  expect([...map.keys()]).toEqual(['locations', 'mining', 'exploration', 'zones'])
  expect(map.get('locations')!.map((i) => i.id)).toEqual(['l1'])
  expect(map.get('mining')!.map((i) => i.id)).toEqual(['Belt'])
  expect(map.get('exploration')).toEqual([])
  expect(map.get('zones')!.map((i) => i.id)).toEqual(['z1'])
})

// ── duplicate names across domains stay distinct rows ────────────────────────────────────────────────
test('a name shared across domains yields distinct rows/items (keyed per domain)', () => {
  const rows = normalizeCatalogRows({
    rows: [rawLocation('loc-x', 'Haven', 'active'), rawMining('mine-x', 'Haven', 'active')],
  })
  expect(rows).toHaveLength(2)
  expect(findCatalogRow(rows, 'locations', 'loc-x')?.domain).toBe('location')
  expect(findCatalogRow(rows, 'mining', 'Haven')?.domain).toBe('mining') // mining keys by name
  // no cross-domain collision: the location's uuid id is not a mining key and vice-versa
  expect(findCatalogRow(rows, 'mining', 'loc-x')).toBeNull()
})

// ── findCatalogRow + lifecycle pass ──────────────────────────────────────────────────────────────────
test('findCatalogRow matches on layer + natural selection id; catalogRowPassesStatus honors the filter', () => {
  const rows = normalizeCatalogRows({ rows: [rawZone('z-1', 'Reach', 'inactive')] })
  const found = findCatalogRow(rows, 'zones', 'z-1')!
  expect(found.name).toBe('Reach')
  expect(catalogRowPassesStatus(found, 'inactive')).toBe(true)
  expect(catalogRowPassesStatus(found, 'active')).toBe(false)
  expect(catalogRowPassesStatus(found, 'all')).toBe(true)
})

// ── inactive selection + camera jump work with NULL metadata (revision/updated_at null) ──────────────
test('an inactive point jumps the camera; an inactive zone frames its whole ring — null metadata OK', () => {
  const inactivePoint = catalogRowToLayerItem(normalizeCatalogRow(rawExploration('e', 'Ghost Site', 'inactive'))!)!
  const pts = representationWorldPoints(inactivePoint.representation)
  expect(pts).toEqual([{ x: 10, y: 20 }])
  const cam = fitCameraToWorldPoints(pts)
  expect(Number.isFinite(cam.k) && cam.k > 0).toBe(true)

  const inactiveZoneRow = normalizeCatalogRow(rawZone('z', 'Ghost Zone', 'inactive'))!
  expect(inactiveZoneRow.revision).toBeNull() // no revision to derive from
  const zoneItem = catalogRowToLayerItem(inactiveZoneRow)!
  const ringPts = representationWorldPoints(zoneItem.representation)
  expect(ringPts.length).toBeGreaterThanOrEqual(3) // frames the whole polygon ring, not a single point
  expect(Number.isFinite(fitCameraToWorldPoints(ringPts).k)).toBe(true)
})

// ── 0271 MARKER-STYLE: location markers keep their SEMANTIC glyph/tone/hub-ring (via markerStyle) ─────
const itemFor = (raw: unknown) => catalogRowToLayerItem(normalizeCatalogRow(raw)!)!

test('a pirate_hunt location retains the danger tone + triangle glyph (no hub ring)', () => {
  const it = itemFor(rawLocation('ph', 'Raider Nest', 'active', { location_type: 'pirate_hunt', activity_type: 'hunt_pirates', reward_tier: 2, base_difficulty: 25 }))
  expect(it.glyph).toBe('triangle')
  expect(it.tone).toBe('var(--color-danger)')
  expect(it.hubRing).toBe(false)
  // and it matches the SHARED policy exactly (no re-implementation)
  const s = markerStyle({ location_type: 'pirate_hunt', activity_type: 'hunt_pirates', reward_tier: 2, base_difficulty: 25 })
  expect(it.tone).toBe(s.color)
  expect(it.glyph).toBe(s.shape)
})

test('a trade_outpost location retains the accent tone + diamond glyph + hub ring', () => {
  const it = itemFor(rawLocation('to', 'Free Port', 'active', { location_type: 'trade_outpost', activity_type: 'trade_visit', reward_tier: 3, base_difficulty: 4 }))
  expect(it.glyph).toBe('diamond')
  expect(it.tone).toBe('var(--color-accent)')
  expect(it.hubRing).toBe(true)
})

test('inactive locations keep the SEMANTIC glyph + hub ring but dim the tone', () => {
  const inactivePirate = itemFor(rawLocation('phx', 'Ghost Nest', 'inactive', { location_type: 'pirate_hunt', activity_type: 'hunt_pirates', reward_tier: 1, base_difficulty: 30 }))
  expect(inactivePirate.glyph).toBe('triangle') // semantic glyph preserved
  expect(inactivePirate.tone).toBe('var(--color-ink-faint)') // dimmed
  expect(inactivePirate.hubRing).toBe(false)

  const inactivePort = itemFor(rawLocation('tox', 'Ghost Port', 'inactive', { location_type: 'trade_outpost', activity_type: 'trade_visit', reward_tier: 3, base_difficulty: 4 }))
  expect(inactivePort.glyph).toBe('diamond') // semantic glyph preserved
  expect(inactivePort.hubRing).toBe(true) // hub ring preserved
  expect(inactivePort.tone).toBe('var(--color-ink-faint)') // dimmed
})

test('null location marker metadata falls back safely (no crash, no hub ring)', () => {
  const it = itemFor(rawLocation('nul', 'Mystery', 'active', { location_type: null, activity_type: null, reward_tier: null, base_difficulty: null }))
  expect(it.glyph).toBe('circle')
  expect(it.hubRing).toBe(false)
  expect(typeof it.tone).toBe('string') // a real token, never undefined
})

test('non-location domains keep flat per-domain styling and never get a hub ring', () => {
  const mine = itemFor(rawMining('m', 'Iron Belt', 'active'))
  expect(mine).toMatchObject({ glyph: 'hex', tone: 'var(--color-warning)' })
  expect(mine.hubRing).toBe(false)
  const zone = itemFor(rawZone('z', 'Reach', 'active'))
  expect(zone.hubRing).toBe(false)
})

test('the active/inactive/all filter never alters an item’s semantic marker classification', () => {
  const rows = normalizeCatalogRows({
    rows: [
      rawLocation('ph-a', 'Nest A', 'active', { location_type: 'pirate_hunt', activity_type: 'hunt_pirates', reward_tier: 2, base_difficulty: 25 }),
      rawLocation('ph-i', 'Nest I', 'inactive', { location_type: 'pirate_hunt', activity_type: 'hunt_pirates', reward_tier: 2, base_difficulty: 25 }),
    ],
  })
  const items = catalogItemsByLayer(rows)
  const all = new Set<LayerId>(['locations', 'mining', 'exploration', 'zones'])
  // every pirate_hunt stays a triangle no matter which lifecycle bucket the filter shows
  for (const status of ['active', 'inactive', 'all'] as const) {
    for (const it of filterVisibleItems(items, { visibleLayers: all, status })) {
      expect(it.glyph).toBe('triangle')
    }
  }
})

// ── a drawable-less row is dropped ───────────────────────────────────────────────────────────────────
test('a row with neither point nor geometry is not drawable → no LayerItem', () => {
  const row: WorldEditorCatalogRow = {
    domain: 'location', entityId: 'x', name: 'Nowhere', lifecycleStatus: 'active',
    revision: null, point: null, geometry: null, updatedAt: null,
    locationType: 'safe_zone', activityType: 'none', rewardTier: 0, baseDifficulty: 0,
  }
  expect(catalogRowToLayerItem(row)).toBeNull()
})

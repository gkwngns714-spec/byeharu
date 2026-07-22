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
import { fitCameraToWorldPoints } from '../src/features/map/galaxyCamera'

// WORLD EDITOR V5 LIFECYCLE — pure proofs for the 0269 catalog model (worldEditorCatalog). No browser/
// DB: normalization (untrusted jsonb → typed rows), the domain↔layer bridge, the per-row selection id,
// and the row→LayerItem projection are all pure. Run: `npx playwright test worldEditorCatalog.spec.ts`.

// Raw server rows (the exact 0269 row contract): revision null for every row; updated_at non-null only
// for zones; point is the anchor/centroid; geometry is the closed vertex ring (zones only).
const rawLocation = (id: string, name: string, lifecycle: string) => ({
  domain: 'location', entity_id: id, name, lifecycle_status: lifecycle,
  revision: null, point: { x: -100, y: 200 }, geometry: null, updated_at: null,
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

// ── a drawable-less row is dropped ───────────────────────────────────────────────────────────────────
test('a row with neither point nor geometry is not drawable → no LayerItem', () => {
  const row: WorldEditorCatalogRow = {
    domain: 'location', entityId: 'x', name: 'Nowhere', lifecycleStatus: 'active',
    revision: null, point: null, geometry: null, updatedAt: null,
  }
  expect(catalogRowToLayerItem(row)).toBeNull()
})

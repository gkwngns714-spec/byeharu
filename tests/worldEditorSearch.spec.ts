import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  searchEntities,
  entityNavigation,
  type EntityMatch,
} from '../src/features/worldeditor/worldEditorSearch'
import { fitCameraToWorldPoints } from '../src/features/map/galaxyCamera'
import { representationWorldPoints } from '../src/features/worldeditor/worldEditorGeometry'
import type { LayerId, LayerItem } from '../src/features/worldeditor/worldEditorTypes'

// WORLD EDITOR V5 — pure proofs for the entity SEARCH + camera-jump navigation (worldEditorSearch).
// No browser/DB: searchEntities / entityNavigation are pure (items + query in → matches / navigation
// out). Reuse is PROVEN structurally too — the module frames through the shared galaxyCamera fit and
// never invents a search index or a second selection/camera model.
// Run: `npx playwright test worldEditorSearch.spec.ts`.

const point = (layer: LayerId, id: string, label: string, x: number, y: number): LayerItem => ({
  layer,
  id,
  label,
  representation: { kind: 'point', world: { x, y } },
  tone: 'var(--color-accent)',
  glyph: 'circle',
})

const polygon = (layer: LayerId, id: string, label: string, ring: { x: number; y: number }[]): LayerItem => ({
  layer,
  id,
  label,
  representation: { kind: 'polygon', ring },
  tone: 'var(--color-danger)',
  glyph: 'circle',
})

/** A world shaped like production: named locations near the origin, a mining field far out, a zone
 *  polygon, and an EMPTY exploration layer (the server-only RLS reality — no client rows). */
const makeItems = (): Map<LayerId, LayerItem[]> =>
  new Map<LayerId, LayerItem[]>([
    [
      'locations',
      [
        point('locations', 'loc-porthaven', 'Porthaven', -100, -100),
        point('locations', 'loc-portside', 'Portside Market', 120, 90),
        point('locations', 'loc-ember', 'Ember Reach', 300, -50),
      ],
    ],
    ['mining', [point('mining', 'Iron Belt', 'Iron Belt', 5000, 5000)]],
    ['exploration', []], // RLS-empty client-side → excluded by absence, never faked
    [
      'zones',
      [polygon('zones', 'zone-1', 'Port Authority Zone', [{ x: 2000, y: 2000 }, { x: 2400, y: 2000 }, { x: 2200, y: 2400 }])],
    ],
  ])

const names = (ms: EntityMatch[]) => ms.map((m) => m.name)

// ── substring, case-insensitivity, cross-domain ──────────────────────────────────────────────────────
test('case-insensitive substring matches across every included domain', () => {
  const items = makeItems()
  // "port" hits two locations + one zone (case-insensitive), across domains
  const ms = searchEntities(items, 'PORT')
  expect(names(ms)).toEqual(
    expect.arrayContaining(['Porthaven', 'Portside Market', 'Port Authority Zone']),
  )
  // a mid-word substring still matches ("Belt" inside "Iron Belt")
  expect(names(searchEntities(items, 'belt'))).toEqual(['Iron Belt'])
  // matches carry their owning domain
  expect(searchEntities(items, 'Iron Belt')[0].domain).toBe('mining')
  expect(searchEntities(items, 'Port Authority')[0].domain).toBe('zones')
})

// ── prefix-before-substring ranking ──────────────────────────────────────────────────────────────────
test('exact → prefix → substring ranking; ties A→Z', () => {
  const items = new Map<LayerId, LayerItem[]>([
    [
      'locations',
      [
        point('locations', 'a', 'Deep Ore', 0, 0), // substring "ore"
        point('locations', 'b', 'Ore Fields', 10, 10), // prefix "ore"
        point('locations', 'c', 'Ore', 20, 20), // exact "ore"
      ],
    ],
    ['mining', []],
    ['exploration', []],
    ['zones', []],
  ])
  expect(names(searchEntities(items, 'ore'))).toEqual(['Ore', 'Ore Fields', 'Deep Ore'])
})

// ── empty query & no-match rules ─────────────────────────────────────────────────────────────────────
test('blank/whitespace query → no results; unmatched query → empty', () => {
  const items = makeItems()
  expect(searchEntities(items, '')).toEqual([])
  expect(searchEntities(items, '   ')).toEqual([])
  expect(searchEntities(items, 'zzzz-nothing')).toEqual([])
})

// ── an empty domain contributes nothing (exploration is RLS-empty client-side) ───────────────────────
test('a domain with no client-available rows yields no matches (exploration excluded by absence)', () => {
  const items = makeItems()
  // nothing in the result set belongs to exploration, even for a query that would match a site name
  for (const m of searchEntities(items, 'e')) expect(m.domain).not.toBe('exploration')
  // and an all-empty world matches nothing
  const empty = new Map<LayerId, LayerItem[]>([
    ['locations', []],
    ['mining', []],
    ['exploration', []],
    ['zones', []],
  ])
  expect(searchEntities(empty, 'port')).toEqual([])
})

// ── the result → (select + camera-frame) wiring, via the PURE handler ────────────────────────────────
test('entityNavigation drives the existing selection model AND frames the camera via the shared fit', () => {
  const items = makeItems()

  const locHit = searchEntities(items, 'Porthaven')[0]
  const locNav = entityNavigation(locHit)
  // (a) selection is the shell's {layer,id} model for that domain's entity
  expect(locNav.selection).toEqual({ layer: 'locations', id: 'loc-porthaven' })
  // (b) camera is EXACTLY galaxyCamera.fitCameraToWorldPoints over the entity's own world points
  expect(locNav.camera).toEqual(fitCameraToWorldPoints(locHit.worldPoints))
  expect(locHit.worldPoints).toEqual([{ x: -100, y: -100 }])

  // a zone (polygon) frames its WHOLE ring, not a single point — same representationWorldPoints path
  const zoneHit = searchEntities(items, 'Port Authority')[0]
  const zoneNav = entityNavigation(zoneHit)
  expect(zoneNav.selection).toEqual({ layer: 'zones', id: 'zone-1' })
  expect(zoneHit.worldPoints).toHaveLength(3)
  const zoneItem = items.get('zones')![0]
  expect(zoneNav.camera).toEqual(fitCameraToWorldPoints(representationWorldPoints(zoneItem.representation)))
  // the camera is a valid presentation camera (finite, bounded)
  expect(Number.isFinite(zoneNav.camera.k) && zoneNav.camera.k > 0).toBe(true)
})

// ── STRUCTURAL: pure navigation only — no writes, no second camera/search engine ─────────────────────
test('worldEditorSearch is pure navigation: no IO, no write, reuses the shared camera fit', () => {
  const here = dirname(fileURLToPath(import.meta.url))
  const src = readFileSync(join(here, '..', 'src', 'features', 'worldeditor', 'worldEditorSearch.ts'), 'utf8')
  // reuses the ONE camera authority + the ONE world-points resolver
  expect(src).toMatch(/from '\.\.\/map\/galaxyCamera'/)
  expect(src).toContain('representationWorldPoints')
  // no IO / no write / no second projection math
  expect(src).not.toMatch(/supabase|\.rpc\(|fetch\(|from '@?supabase/)
  expect(src).not.toMatch(/insert|update|upsert|delete/i)
  expect(src).not.toMatch(/worldToViewBox|viewBoxToWorld/) // framing goes through galaxyCamera, not a local projection
})

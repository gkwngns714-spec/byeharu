import { test, expect } from '@playwright/test'
import {
  reactivationNeedsDetail,
  catalogReactivateEnvelope,
  detailReactivateEnvelope,
} from '../src/features/worldeditor/worldEditorReactivate'
import { commandRpcName } from '../src/features/worldeditor/commandContract'
import { normalizeCatalogRow } from '../src/features/worldeditor/worldEditorCatalog'

// WORLD EDITOR V5 LIFECYCLE — pure proofs that reactivation issues the CORRECT command per domain with
// the CORRECT payload (worldEditorReactivate). No browser/DB: the builders are pure. zone/location pass
// the 0270 detail `reactivation_expected` VERBATIM (no client reconstruction); mining/exploration
// reactivate straight from the catalog row with reward_bundle_json:null.
// Run: `npx playwright test worldEditorReactivate.spec.ts`.

const mining = normalizeCatalogRow({
  domain: 'mining', entity_id: 'm-uuid', name: 'Iron Belt', lifecycle_status: 'inactive',
  revision: null, point: { x: 5000, y: -4200 }, geometry: null, updated_at: null,
})!
const exploration = normalizeCatalogRow({
  domain: 'exploration', entity_id: 'e-uuid', name: 'Nebula Trace', lifecycle_status: 'inactive',
  revision: null, point: { x: 12, y: -34 }, geometry: null, updated_at: null,
})!
const zoneRow = normalizeCatalogRow({
  domain: 'zone', entity_id: 'zone-uuid', name: 'Crimson Reach', lifecycle_status: 'inactive',
  revision: null, point: { x: 800, y: -800 },
  geometry: { kind: 'ring', ring: [[700, -900], [900, -900], [800, -700], [700, -900]] },
  updated_at: '2026-07-20T00:00:00Z',
})!
const locationRow = normalizeCatalogRow({
  domain: 'location', entity_id: 'loc-uuid', name: 'Porthaven', lifecycle_status: 'inactive',
  revision: null, point: { x: -100, y: 200 }, geometry: null, updated_at: null,
})!

// ── which path each domain takes ─────────────────────────────────────────────────────────────────────
test('zone/location need the detail reader; mining/exploration reactivate from the catalog row', () => {
  expect(reactivationNeedsDetail(zoneRow)).toBe(true)
  expect(reactivationNeedsDetail(locationRow)).toBe(true)
  expect(reactivationNeedsDetail(mining)).toBe(false)
  expect(reactivationNeedsDetail(exploration)).toBe(false)
})

// ── mining / exploration: straight from the catalog row (target_id = name, reward_bundle_json:null) ──
test('mining reactivate issues mining_field_set_active from the catalog row', () => {
  const env = catalogReactivateEnvelope(mining, 'req-1')
  expect(env.commandType).toBe('mining_field_set_active')
  expect(commandRpcName(env.commandType)).toBe('mining_field_set_active')
  expect(env.payload).toEqual({
    target_id: 'Iron Belt', // mining is name-addressed
    expected: { name: 'Iron Belt', space_x: 5000, space_y: -4200, reward_bundle_json: null },
    is_active: true,
  })
})

test('exploration reactivate issues exploration_site_set_active from the catalog row', () => {
  const env = catalogReactivateEnvelope(exploration, 'req-2')
  expect(env.commandType).toBe('exploration_site_set_active')
  expect(env.payload).toEqual({
    target_id: 'Nebula Trace',
    expected: { name: 'Nebula Trace', space_x: 12, space_y: -34, reward_bundle_json: null },
    is_active: true,
  })
})

test('catalogReactivateEnvelope refuses zone/location (they must use the detail reader)', () => {
  expect(() => catalogReactivateEnvelope(zoneRow, 'req')).toThrow()
  expect(() => catalogReactivateEnvelope(locationRow, 'req')).toThrow()
})

// ── zone: detail.reactivation_expected passed VERBATIM as expected ──────────────────────────────────
test('zone reactivate issues zone_set_active with the detail expected passed verbatim', () => {
  const expected = { name: 'Crimson Reach', source: 'drawn', location_id: null }
  const env = detailReactivateEnvelope('zone', zoneRow.entityId, expected, 'req-3')
  expect(env.commandType).toBe('zone_set_active')
  expect(commandRpcName(env.commandType)).toBe('zone_set_active')
  expect(env.payload).toEqual({ target_id: 'zone-uuid', expected })
  // verbatim: the exact object reference is passed through (no reconstruction)
  expect((env.payload as { expected: unknown }).expected).toBe(expected)
})

// ── location: detail expected verbatim + fields = that snapshot with status→active ──────────────────
test('location reactivate issues location_update: expected verbatim, fields = snapshot with status active', () => {
  const expected = {
    name: 'Porthaven', location_type: 'port', activity_type: 'trade', x: -100, y: 200,
    reward_tier: 2, base_difficulty: 3, min_power_required: 0, is_public: true,
    territory_radius: null, status: 'hidden', // the CURRENT (inactive) raw status
  }
  const env = detailReactivateEnvelope('location', locationRow.entityId, expected, 'req-4')
  expect(env.commandType).toBe('location_update')
  const payload = env.payload as { target_id: string; expected: Record<string, unknown>; fields: Record<string, unknown> }
  expect(payload.target_id).toBe('loc-uuid')
  // expected is the snapshot VERBATIM (status stays the current inactive value — the optimistic baseline)
  expect(payload.expected).toEqual(expected)
  expect(payload.expected.status).toBe('hidden')
  // fields is the same snapshot with ONLY status flipped to 'active' (reactivation = set status active)
  expect(payload.fields).toEqual({ ...expected, status: 'active' })
  expect(payload.fields.status).toBe('active')
})

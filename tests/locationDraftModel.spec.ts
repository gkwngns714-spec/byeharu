import { test, expect } from '@playwright/test'
import {
  EMPTY_CREATE_PAYLOAD,
  beginCreate,
  computeSourceFingerprint,
  draftSourceStatus,
  draftToLayerItem,
  forkEdit,
  isDirty,
  parseStoredDraft,
  patch,
  validateDraftBounds,
} from '../src/features/worldeditor/locationDraftModel'
import { locationLayerAdapter } from '../src/features/worldeditor/worldEditorAdapters'
import type { WorldEditorData } from '../src/features/worldeditor/worldEditorData'
import type { MapLocation } from '../src/features/map/mapTypes'

// WORLD EDITOR V1B-1 — pure proofs for the location-draft model. No browser/DB: every function is
// deterministic (ids + timestamps passed in). Run: `npx playwright test locationDraftModel.spec.ts`.

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

const T0 = 1_700_000_000_000
const T1 = T0 + 60_000

// ── fork / patch / dirty ─────────────────────────────────────────────────────────────────────────────
test('forkEdit copies the live payload, pins source id + revision + snapshot, and starts clean', () => {
  const d = forkEdit(loc(), 'draft-a', T0)
  expect(d.draftId).toBe('draft-a')
  expect(d.createdAt).toBe(T0)
  expect(d.updatedAt).toBe(T0)
  expect(d.mode.kind).toBe('edit')
  if (d.mode.kind !== 'edit') throw new Error('unreachable')
  expect(d.mode.sourceId).toBe('loc-1')
  expect(d.mode.sourceRevision).toBe(computeSourceFingerprint(loc()))
  expect(d.mode.sourceSnapshot.name).toBe('Aurelia Port')
  expect(d.payload).toEqual(d.mode.sourceSnapshot)
  expect(isDirty(d)).toBe(false)
})

test('patch is immutable, bumps updatedAt, flips dirty — and patching back to the original un-dirties', () => {
  const d = forkEdit(loc(), 'draft-a', T0)
  const p1 = patch(d, { name: 'Aurelia Prime', x: 500 }, T1)
  expect(p1).not.toBe(d)
  expect(d.payload.name).toBe('Aurelia Port') // original untouched
  expect(p1.payload.name).toBe('Aurelia Prime')
  expect(p1.payload.x).toBe(500)
  expect(p1.updatedAt).toBe(T1)
  expect(isDirty(p1)).toBe(true)
  // fingerprint-equality dirtiness: restoring the original values returns to clean
  const p2 = patch(p1, { name: 'Aurelia Port', x: 120 }, T1 + 1)
  expect(isDirty(p2)).toBe(false)
})

test('beginCreate starts at the blank payload (clean); any change makes it dirty', () => {
  const d = beginCreate('draft-new', T0)
  expect(d.mode).toEqual({ kind: 'create' })
  expect(d.payload).toEqual(EMPTY_CREATE_PAYLOAD)
  expect(isDirty(d)).toBe(false)
  expect(isDirty(patch(d, { name: 'Amber Shoal' }, T1))).toBe(true)
})

// ── fingerprint stability ────────────────────────────────────────────────────────────────────────────
test('fingerprint is stable across calls and extra properties, and moves on any payload field change', () => {
  expect(computeSourceFingerprint(loc())).toBe(computeSourceFingerprint(loc()))
  // extra non-payload properties (e.g. the live row's id) are ignored
  expect(computeSourceFingerprint(loc({ id: 'other-id' }))).toBe(computeSourceFingerprint(loc()))
  // every payload field participates
  expect(computeSourceFingerprint(loc({ name: 'X' }))).not.toBe(computeSourceFingerprint(loc()))
  expect(computeSourceFingerprint(loc({ x: 121 }))).not.toBe(computeSourceFingerprint(loc()))
  expect(computeSourceFingerprint(loc({ territory_radius: null }))).not.toBe(computeSourceFingerprint(loc()))
  expect(computeSourceFingerprint(loc({ is_public: false }))).not.toBe(computeSourceFingerprint(loc()))
})

// ── source status: current / changed / missing ───────────────────────────────────────────────────────
test('draftSourceStatus: current when live matches the forked revision; changed when it moved; missing when gone', () => {
  const d = forkEdit(loc(), 'draft-a', T0)
  expect(draftSourceStatus(d, loc())).toBe('current')
  expect(draftSourceStatus(d, loc({ base_difficulty: 9 }))).toBe('source_changed')
  expect(draftSourceStatus(d, undefined)).toBe('source_missing')
  // a create draft has no source — always current
  expect(draftSourceStatus(beginCreate('draft-new', T0), undefined)).toBe('current')
})

// ── bounds: FLAGGED, never clamped, never thrown ─────────────────────────────────────────────────────
test('out-of-bounds coordinates are flagged — the payload keeps its exact values (no clamp, no throw)', () => {
  const inside = beginCreate('d', T0)
  expect(validateDraftBounds(inside.payload)).toBe(true)

  const far = patch(inside, { x: 20_000, y: -30_000 }, T1)
  expect(validateDraftBounds(far.payload)).toBe(false)
  expect(far.payload.x).toBe(20_000) // NOT snapped to the edge
  expect(far.payload.y).toBe(-30_000)

  // boundary values are inside the closed domain; non-finite values are flagged, never thrown
  expect(validateDraftBounds({ ...inside.payload, x: 10_000, y: -10_000 })).toBe(true)
  expect(validateDraftBounds({ ...inside.payload, x: Number.NaN })).toBe(false)
  expect(validateDraftBounds({ ...inside.payload, y: Number.POSITIVE_INFINITY })).toBe(false)
})

// ── preview shape parity with the live locations layer ───────────────────────────────────────────────
test('draftToLayerItem has EXACTLY the LayerItem shape locationLayerAdapter.readItems produces', () => {
  const DATA: WorldEditorData = { locations: [loc()], zoneRefs: [], miningFields: [], explorationSites: [], zones: [] }
  const liveItem = locationLayerAdapter.readItems(DATA)[0]
  const draftItem = draftToLayerItem(forkEdit(loc(), 'draft-a', T0))

  // identical key set → the preview is structurally interchangeable with a live layer item
  expect(Object.keys(draftItem).sort()).toEqual(Object.keys(liveItem).sort())
  expect(draftItem.layer).toBe('locations')
  expect(draftItem.id).toBe('draft-a')
  expect(draftItem.representation).toEqual({ kind: 'point', world: { x: 120, y: -80 } })
  // unforked payload → same markerStyle decision as the live row
  expect(draftItem.tone).toBe(liveItem.tone)
  expect(draftItem.glyph).toBe(liveItem.glyph)
  expect(draftItem.tone.startsWith('var(--color-')).toBe(true)

  // an unnamed create draft still renders an honest label
  expect(draftToLayerItem(beginCreate('draft-new', T0)).label).toBe('New location')
})

// ── stored-blob rehydration parsing ──────────────────────────────────────────────────────────────────
test('parseStoredDraft round-trips a real draft and drops garbage instead of throwing', () => {
  const d = patch(forkEdit(loc(), 'draft-a', T0), { name: 'Aurelia Prime' }, T1)
  expect(parseStoredDraft(JSON.stringify(d))).toEqual(d)
  const c = beginCreate('draft-new', T0)
  expect(parseStoredDraft(JSON.stringify(c))).toEqual(c)

  expect(parseStoredDraft('not json at all')).toBeNull()
  expect(parseStoredDraft('null')).toBeNull()
  expect(parseStoredDraft('{}')).toBeNull()
  expect(parseStoredDraft(JSON.stringify({ ...d, payload: { name: 42 } }))).toBeNull()
  expect(parseStoredDraft(JSON.stringify({ ...d, mode: { kind: 'publish' } }))).toBeNull()
})

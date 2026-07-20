import { test, expect } from '@playwright/test'
import {
  EMPTY_MINING_CREATE_PAYLOAD,
  MINING_DRAFT_DESCRIPTOR,
  beginCreate,
  computeSourceFingerprint,
  draftSourceStatus,
  draftToLayerItem,
  forkEdit,
  isDirty,
  parseStoredDraft,
  patch,
  validateDraftBounds,
} from '../src/features/worldeditor/miningDraftModel'
import { miningLayerAdapter } from '../src/features/worldeditor/worldEditorAdapters'
import type { WorldEditorData } from '../src/features/worldeditor/worldEditorData'
import type { MiningField } from '../src/features/mining/miningTypes'

// WORLD EDITOR V2A PR-2 — pure proofs for the mining-draft model (the mining binding of the generic
// draft core), mirroring tests/locationDraftModel.spec.ts. No browser/DB: every function is
// deterministic (ids + timestamps passed in). Run: `npx playwright test miningDraftModel.spec.ts`.

const field = (over: Partial<MiningField> = {}): MiningField => ({
  name: 'Ferrite Shoal',
  space_x: 1200,
  space_y: -400,
  ...over,
})

const T0 = 1_700_000_000_000
const T1 = T0 + 60_000

// ── fork / patch / dirty ─────────────────────────────────────────────────────────────────────────────
test('forkEdit copies the live payload, pins source id (the name) + revision + snapshot, and starts clean', () => {
  const d = forkEdit(field(), 'draft-a', T0)
  expect(d.draftId).toBe('draft-a')
  expect(d.createdAt).toBe(T0)
  expect(d.updatedAt).toBe(T0)
  expect(d.mode.kind).toBe('edit')
  if (d.mode.kind !== 'edit') throw new Error('unreachable')
  // mining has NO client-visible uuid — the unique natural key (the name) is the live id
  expect(d.mode.sourceId).toBe('Ferrite Shoal')
  expect(d.mode.sourceRevision).toBe(
    computeSourceFingerprint(MINING_DRAFT_DESCRIPTOR.projectFromLive(field())),
  )
  expect(d.mode.sourceSnapshot.name).toBe('Ferrite Shoal')
  expect(d.payload).toEqual(d.mode.sourceSnapshot)
  expect(isDirty(d)).toBe(false)
})

test('patch is immutable, bumps updatedAt, flips dirty — and patching back to the original un-dirties', () => {
  const d = forkEdit(field(), 'draft-a', T0)
  const p1 = patch(d, { name: 'Ferrite Deep', space_x: 500 }, T1)
  expect(p1).not.toBe(d)
  expect(d.payload.name).toBe('Ferrite Shoal') // original untouched
  expect(p1.payload.name).toBe('Ferrite Deep')
  expect(p1.payload.space_x).toBe(500)
  expect(p1.updatedAt).toBe(T1)
  expect(isDirty(p1)).toBe(true)
  // fingerprint-equality dirtiness: restoring the original values returns to clean
  const p2 = patch(p1, { name: 'Ferrite Shoal', space_x: 1200 }, T1 + 1)
  expect(isDirty(p2)).toBe(false)
})

test('beginCreate starts at the blank payload (clean, bundle null); any change makes it dirty', () => {
  const d = beginCreate('draft-new', T0)
  expect(d.mode).toEqual({ kind: 'create' })
  expect(d.payload).toEqual(EMPTY_MINING_CREATE_PAYLOAD)
  expect(d.payload.reward_bundle_json).toBeNull()
  expect(isDirty(d)).toBe(false)
  expect(isDirty(patch(d, { name: 'Amber Vein' }, T1))).toBe(true)
  // authoring a local bundle is a payload change like any other — it flips dirty
  expect(
    isDirty(patch(d, { reward_bundle_json: { items: [{ item_id: 'ore_iron', quantity: 2 }] } }, T1)),
  ).toBe(true)
})

// ── projectFromLive: the CREATE-only bundle is NEVER read from a live row ───────────────────────────
test('projectFromLive nulls reward_bundle_json — even when a rogue live object carries one', () => {
  expect(MINING_DRAFT_DESCRIPTOR.projectFromLive(field())).toEqual({
    name: 'Ferrite Shoal',
    space_x: 1200,
    space_y: -400,
    reward_bundle_json: null,
  })
  // a live row can never leak a bundle into the draft layer (RLS forbids reading it; the read
  // contract never returns it) — the projection is null even if the object HAD such a property
  const rogue = { ...field(), reward_bundle_json: { items: [{ item_id: 'x', quantity: 1 }] } }
  expect(MINING_DRAFT_DESCRIPTOR.projectFromLive(rogue as MiningField).reward_bundle_json).toBeNull()
  // and an edit fork therefore starts with a null bundle
  expect(forkEdit(field(), 'draft-a', T0).payload.reward_bundle_json).toBeNull()
})

// ── fingerprint stability ────────────────────────────────────────────────────────────────────────────
test('fingerprint is stable across calls and extra properties, and moves on any payload field change', () => {
  const p = MINING_DRAFT_DESCRIPTOR.projectFromLive(field())
  expect(computeSourceFingerprint(p)).toBe(computeSourceFingerprint({ ...p }))
  // extra non-payload properties are ignored
  expect(computeSourceFingerprint({ ...p, extra: 'ignored' } as typeof p)).toBe(
    computeSourceFingerprint(p),
  )
  // every payload field participates
  expect(computeSourceFingerprint({ ...p, name: 'X' })).not.toBe(computeSourceFingerprint(p))
  expect(computeSourceFingerprint({ ...p, space_x: 1201 })).not.toBe(computeSourceFingerprint(p))
  expect(computeSourceFingerprint({ ...p, space_y: 0 })).not.toBe(computeSourceFingerprint(p))
  expect(
    computeSourceFingerprint({ ...p, reward_bundle_json: { items: [{ item_id: 'a', quantity: 1 }] } }),
  ).not.toBe(computeSourceFingerprint(p))
})

// ── source status: current / changed / missing ───────────────────────────────────────────────────────
test('draftSourceStatus: current when live matches the forked revision; changed when it moved; missing when gone', () => {
  const d = forkEdit(field(), 'draft-a', T0)
  expect(draftSourceStatus(d, field())).toBe('current')
  expect(draftSourceStatus(d, field({ space_x: 1300 }))).toBe('source_changed')
  expect(draftSourceStatus(d, undefined)).toBe('source_missing')
  // a create draft has no source — always current
  expect(draftSourceStatus(beginCreate('draft-new', T0), undefined)).toBe('current')
})

// ── bounds: FLAGGED, never clamped, never thrown ─────────────────────────────────────────────────────
test('out-of-bounds coordinates are flagged — the payload keeps its exact values (no clamp, no throw)', () => {
  const inside = beginCreate('d', T0)
  expect(validateDraftBounds(inside.payload)).toBe(true)

  const far = patch(inside, { space_x: 20_000, space_y: -30_000 }, T1)
  expect(validateDraftBounds(far.payload)).toBe(false)
  expect(far.payload.space_x).toBe(20_000) // NOT snapped to the edge
  expect(far.payload.space_y).toBe(-30_000)

  // boundary values are inside the closed domain; non-finite values are flagged, never thrown
  expect(validateDraftBounds({ ...inside.payload, space_x: 10_000, space_y: -10_000 })).toBe(true)
  expect(validateDraftBounds({ ...inside.payload, space_x: Number.NaN })).toBe(false)
  expect(validateDraftBounds({ ...inside.payload, space_y: Number.POSITIVE_INFINITY })).toBe(false)
})

// ── preview shape parity with the live mining layer (hex glyph, --color-warning tone) ───────────────
test('draftToLayerItem has EXACTLY the LayerItem shape miningLayerAdapter.readItems produces', () => {
  const DATA: WorldEditorData = { locations: [], zoneRefs: [], miningFields: [field()], explorationSites: [], zones: [] }
  const liveItem = miningLayerAdapter.readItems(DATA)[0]
  const draftItem = draftToLayerItem(forkEdit(field(), 'draft-a', T0))

  // identical key set → the preview is structurally interchangeable with a live layer item
  expect(Object.keys(draftItem).sort()).toEqual(Object.keys(liveItem).sort())
  expect(draftItem.layer).toBe('mining')
  expect(draftItem.id).toBe('draft-a')
  expect(draftItem.representation).toEqual({ kind: 'point', world: { x: 1200, y: -400 } })
  // the SAME visual language as the live mining layer — hex glyph, --color-warning tone
  expect(draftItem.glyph).toBe('hex')
  expect(draftItem.tone).toBe('var(--color-warning)')
  expect(draftItem.glyph).toBe(liveItem.glyph)
  expect(draftItem.tone).toBe(liveItem.tone)

  // an unnamed create draft still renders an honest label
  expect(draftToLayerItem(beginCreate('draft-new', T0)).label).toBe('New field')
})

// ── stored-blob rehydration parsing ──────────────────────────────────────────────────────────────────
test('parseStoredDraft round-trips a real draft and drops garbage instead of throwing', () => {
  const d = patch(forkEdit(field(), 'draft-a', T0), { name: 'Ferrite Deep' }, T1)
  expect(parseStoredDraft(JSON.stringify(d))).toEqual(d)
  const c = patch(
    beginCreate('draft-new', T0),
    { reward_bundle_json: { metal: 5, items: [{ item_id: 'ore_iron', quantity: 3 }] } },
    T1,
  )
  expect(parseStoredDraft(JSON.stringify(c))).toEqual(c)

  expect(parseStoredDraft('not json at all')).toBeNull()
  expect(parseStoredDraft('null')).toBeNull()
  expect(parseStoredDraft('{}')).toBeNull()
  expect(parseStoredDraft(JSON.stringify({ ...d, payload: { name: 42 } }))).toBeNull()
  // reward_bundle_json must be null or an object — an array/string blob is dropped
  expect(
    parseStoredDraft(JSON.stringify({ ...c, payload: { ...c.payload, reward_bundle_json: [] } })),
  ).toBeNull()
  expect(
    parseStoredDraft(JSON.stringify({ ...c, payload: { ...c.payload, reward_bundle_json: 'x' } })),
  ).toBeNull()
  expect(parseStoredDraft(JSON.stringify({ ...d, mode: { kind: 'publish' } }))).toBeNull()
})

// ── descriptor identity (the ONE binding stays distinct from the location domain) ───────────────────
test('the mining descriptor keys its own storage namespace and identifies rows by name', () => {
  expect(MINING_DRAFT_DESCRIPTOR.domainId).toBe('mining')
  expect(MINING_DRAFT_DESCRIPTOR.storageKeyPrefix).toBe('byeharu.worldEditor.miningDraft.v1:')
  expect(MINING_DRAFT_DESCRIPTOR.liveId(field())).toBe('Ferrite Shoal')
})

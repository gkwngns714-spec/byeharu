import { test, expect } from '@playwright/test'
import {
  EMPTY_EXPLORATION_CREATE_PAYLOAD,
  EXPLORATION_DRAFT_DESCRIPTOR,
  beginCreate,
  computeSourceFingerprint,
  draftSourceStatus,
  draftToLayerItem,
  forkEdit,
  isDirty,
  parseStoredDraft,
  patch,
  validateDraftBounds,
} from '../src/features/worldeditor/explorationDraftModel'
import { explorationLayerAdapter } from '../src/features/worldeditor/worldEditorAdapters'
import type { WorldEditorData } from '../src/features/worldeditor/worldEditorData'
import type { ExplorationSiteLite } from '../src/features/exploration/explorationTypes'

// WORLD EDITOR V2C — pure proofs for the exploration-draft model (the exploration binding of the
// generic draft core), mirroring tests/miningDraftModel.spec.ts. No browser/DB: every function is
// deterministic (ids + timestamps passed in). Run: `npx playwright test explorationDraftModel.spec.ts`.

const site = (over: Partial<ExplorationSiteLite> = {}): ExplorationSiteLite => ({
  name: 'Derelict Listening Post',
  space_x: -1200,
  space_y: 850,
  ...over,
})

const T0 = 1_700_000_000_000
const T1 = T0 + 60_000

// ── fork / patch / dirty ─────────────────────────────────────────────────────────────────────────────
test('forkEdit copies the live payload, pins source id (the name) + revision + snapshot, and starts clean', () => {
  const d = forkEdit(site(), 'draft-a', T0)
  expect(d.draftId).toBe('draft-a')
  expect(d.createdAt).toBe(T0)
  expect(d.updatedAt).toBe(T0)
  expect(d.mode.kind).toBe('edit')
  if (d.mode.kind !== 'edit') throw new Error('unreachable')
  // exploration exposes NO client-visible uuid — the unique natural key (the name) is the live id
  expect(d.mode.sourceId).toBe('Derelict Listening Post')
  expect(d.mode.sourceRevision).toBe(
    computeSourceFingerprint(EXPLORATION_DRAFT_DESCRIPTOR.projectFromLive(site())),
  )
  expect(d.mode.sourceSnapshot.name).toBe('Derelict Listening Post')
  expect(d.payload).toEqual(d.mode.sourceSnapshot)
  expect(isDirty(d)).toBe(false)
})

test('patch is immutable, bumps updatedAt, flips dirty — and patching back to the original un-dirties', () => {
  const d = forkEdit(site(), 'draft-a', T0)
  const p1 = patch(d, { name: 'Silent Relay', space_x: 500 }, T1)
  expect(p1).not.toBe(d)
  expect(d.payload.name).toBe('Derelict Listening Post') // original untouched
  expect(p1.payload.name).toBe('Silent Relay')
  expect(p1.payload.space_x).toBe(500)
  expect(p1.updatedAt).toBe(T1)
  expect(isDirty(p1)).toBe(true)
  // fingerprint-equality dirtiness: restoring the original values returns to clean
  const p2 = patch(p1, { name: 'Derelict Listening Post', space_x: -1200 }, T1 + 1)
  expect(isDirty(p2)).toBe(false)
})

test('beginCreate starts at the blank payload (clean, bundle null); any change makes it dirty', () => {
  const d = beginCreate('draft-new', T0)
  expect(d.mode).toEqual({ kind: 'create' })
  expect(d.payload).toEqual(EMPTY_EXPLORATION_CREATE_PAYLOAD)
  expect(d.payload.reward_bundle_json).toBeNull()
  expect(isDirty(d)).toBe(false)
  expect(isDirty(patch(d, { name: 'Anomalous Echo' }, T1))).toBe(true)
  // authoring a local bundle is a payload change like any other — it flips dirty
  expect(
    isDirty(patch(d, { reward_bundle_json: { items: [{ item_id: 'scan_data', quantity: 2 }] } }, T1)),
  ).toBe(true)
})

// ── projectFromLive: the CREATE-only bundle is NEVER read from a live row ───────────────────────────
test('projectFromLive nulls reward_bundle_json — even when a rogue live object carries one', () => {
  expect(EXPLORATION_DRAFT_DESCRIPTOR.projectFromLive(site())).toEqual({
    name: 'Derelict Listening Post',
    space_x: -1200,
    space_y: 850,
    reward_bundle_json: null,
  })
  // a live row can never leak a bundle into the draft layer (exploration_sites is RLS server-only;
  // the editor's SELECT reads name + coords only) — the projection is null even if the object HAD
  // such a property
  const rogue = { ...site(), reward_bundle_json: { items: [{ item_id: 'x', quantity: 1 }] } }
  expect(
    EXPLORATION_DRAFT_DESCRIPTOR.projectFromLive(rogue as ExplorationSiteLite).reward_bundle_json,
  ).toBeNull()
  // and an edit fork therefore starts with a null bundle
  expect(forkEdit(site(), 'draft-a', T0).payload.reward_bundle_json).toBeNull()
})

// ── fingerprint stability ────────────────────────────────────────────────────────────────────────────
test('fingerprint is stable across calls and extra properties, and moves on any payload field change', () => {
  const p = EXPLORATION_DRAFT_DESCRIPTOR.projectFromLive(site())
  expect(computeSourceFingerprint(p)).toBe(computeSourceFingerprint({ ...p }))
  // extra non-payload properties are ignored
  expect(computeSourceFingerprint({ ...p, extra: 'ignored' } as typeof p)).toBe(
    computeSourceFingerprint(p),
  )
  // every payload field participates
  expect(computeSourceFingerprint({ ...p, name: 'X' })).not.toBe(computeSourceFingerprint(p))
  expect(computeSourceFingerprint({ ...p, space_x: -1201 })).not.toBe(computeSourceFingerprint(p))
  expect(computeSourceFingerprint({ ...p, space_y: 0 })).not.toBe(computeSourceFingerprint(p))
  expect(
    computeSourceFingerprint({ ...p, reward_bundle_json: { items: [{ item_id: 'a', quantity: 1 }] } }),
  ).not.toBe(computeSourceFingerprint(p))
})

// ── source status: current / changed / missing ───────────────────────────────────────────────────────
test('draftSourceStatus: current when live matches the forked revision; changed when it moved; missing when gone', () => {
  const d = forkEdit(site(), 'draft-a', T0)
  expect(draftSourceStatus(d, site())).toBe('current')
  expect(draftSourceStatus(d, site({ space_x: -1300 }))).toBe('source_changed')
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

// ── preview shape parity with the live exploration layer (diamond glyph, --color-accent tone) ───────
test('draftToLayerItem has EXACTLY the LayerItem shape explorationLayerAdapter.readItems produces', () => {
  const DATA: WorldEditorData = { locations: [], miningFields: [], explorationSites: [site()], zones: [] }
  const liveItem = explorationLayerAdapter.readItems(DATA)[0]
  const draftItem = draftToLayerItem(forkEdit(site(), 'draft-a', T0))

  // identical key set → the preview is structurally interchangeable with a live layer item
  expect(Object.keys(draftItem).sort()).toEqual(Object.keys(liveItem).sort())
  expect(draftItem.layer).toBe('exploration')
  expect(draftItem.id).toBe('draft-a')
  expect(draftItem.representation).toEqual({ kind: 'point', world: { x: -1200, y: 850 } })
  // the SAME visual language as the live exploration layer — diamond glyph, --color-accent tone
  expect(draftItem.glyph).toBe('diamond')
  expect(draftItem.tone).toBe('var(--color-accent)')
  expect(draftItem.glyph).toBe(liveItem.glyph)
  expect(draftItem.tone).toBe(liveItem.tone)

  // an unnamed create draft still renders an honest label
  expect(draftToLayerItem(beginCreate('draft-new', T0)).label).toBe('New site')
})

// ── stored-blob rehydration parsing ──────────────────────────────────────────────────────────────────
test('parseStoredDraft round-trips a real draft and drops garbage instead of throwing', () => {
  const d = patch(forkEdit(site(), 'draft-a', T0), { name: 'Silent Relay' }, T1)
  expect(parseStoredDraft(JSON.stringify(d))).toEqual(d)
  const c = patch(
    beginCreate('draft-new', T0),
    { reward_bundle_json: { metal: 25, items: [{ item_id: 'scan_data', quantity: 3 }] } },
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

// ── descriptor identity (the ONE binding stays distinct from the location + mining domains) ─────────
test('the exploration descriptor keys its own storage namespace and identifies rows by name', () => {
  expect(EXPLORATION_DRAFT_DESCRIPTOR.domainId).toBe('exploration')
  expect(EXPLORATION_DRAFT_DESCRIPTOR.storageKeyPrefix).toBe('byeharu.worldEditor.explorationDraft.v1:')
  expect(EXPLORATION_DRAFT_DESCRIPTOR.liveId(site())).toBe('Derelict Listening Post')
})

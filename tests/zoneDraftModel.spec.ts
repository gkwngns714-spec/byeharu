import { test, expect } from '@playwright/test'
import {
  EMPTY_ZONE_CREATE_PAYLOAD,
  ZONE_DRAFT_DESCRIPTOR,
  beginCreate,
  computeSourceFingerprint,
  draftSourceStatus,
  draftToLayerItem,
  forkEdit,
  isDirty,
  parseStoredDraft,
  patch,
  validateDraftBounds,
} from '../src/features/worldeditor/zoneDraftModel'
import { zoneLayerAdapter } from '../src/features/worldeditor/worldEditorAdapters'
import type { WorldEditorData } from '../src/features/worldeditor/worldEditorData'
import type { LiveDangerZone } from '../src/features/worldeditor/zoneDraftTypes'

// WORLD EDITOR V3A PR-2 — pure proofs for the zone-draft model (the zone binding of the generic
// draft core), mirroring tests/miningDraftModel.spec.ts. No browser/DB: every function is
// deterministic (ids + timestamps passed in). Run: `npx playwright test zoneDraftModel.spec.ts`.

/** A live danger zone as get_danger_zones returns it: CLOSED ring (first point repeated last). */
const zone = (over: Partial<LiveDangerZone> = {}): LiveDangerZone => ({
  id: 'a3d2b1c0-0000-4000-8000-000000000001',
  name: 'Crimson Reach',
  source: 'drawn',
  location_id: null,
  ring: [
    [0, 0],
    [400, 0],
    [400, 400],
    [0, 400],
    [0, 0],
  ],
  ...over,
})

const T0 = 1_700_000_000_000
const T1 = T0 + 60_000

// ── fork / patch / dirty ─────────────────────────────────────────────────────────────────────────────
test('forkEdit materializes the live ring to an OPEN polygon, pins the uuid + revision + snapshot, and starts clean', () => {
  const d = forkEdit(zone(), 'draft-a', T0)
  expect(d.draftId).toBe('draft-a')
  expect(d.createdAt).toBe(T0)
  expect(d.updatedAt).toBe(T0)
  expect(d.mode.kind).toBe('edit')
  if (d.mode.kind !== 'edit') throw new Error('unreachable')
  // danger_zones exposes a REAL uuid — the live id is NOT a natural-key name
  expect(d.mode.sourceId).toBe('a3d2b1c0-0000-4000-8000-000000000001')
  expect(d.mode.sourceRevision).toBe(
    computeSourceFingerprint(ZONE_DRAFT_DESCRIPTOR.projectFromLive(zone())),
  )
  // the CLOSED live ring materializes to an OPEN editable ring (closing duplicate dropped)
  expect(d.payload.geometry).toEqual({
    kind: 'polygon',
    vertices: [
      { x: 0, y: 0 },
      { x: 400, y: 0 },
      { x: 400, y: 400 },
      { x: 0, y: 400 },
    ],
  })
  expect(d.payload.name).toBe('Crimson Reach')
  expect(d.payload.zone_kind).toBe('pirate')
  expect(d.payload.attach_location_id).toBeNull()
  expect(d.payload).toEqual(d.mode.sourceSnapshot)
  expect(isDirty(d)).toBe(false)
})

test('patch is immutable, bumps updatedAt, flips dirty — and patching back to the original un-dirties (geometry included)', () => {
  const d = forkEdit(zone(), 'draft-a', T0)
  const movedGeometry = {
    kind: 'polygon' as const,
    vertices: [
      { x: 0, y: 0 },
      { x: 500, y: 0 },
      { x: 400, y: 400 },
      { x: 0, y: 400 },
    ],
  }
  const p1 = patch(d, { name: 'Crimson Deep', geometry: movedGeometry }, T1)
  expect(p1).not.toBe(d)
  expect(d.payload.name).toBe('Crimson Reach') // original untouched
  expect(p1.payload.name).toBe('Crimson Deep')
  expect(p1.payload.geometry).toEqual(movedGeometry)
  expect(p1.updatedAt).toBe(T1)
  expect(isDirty(p1)).toBe(true)
  // fingerprint-equality dirtiness: restoring the original values returns to clean
  const p2 = patch(
    p1,
    { name: 'Crimson Reach', geometry: d.payload.geometry },
    T1 + 1,
  )
  expect(isDirty(p2)).toBe(false)
})

test('beginCreate starts at the blank payload (empty open polygon, clean); any geometry change makes it dirty', () => {
  const d = beginCreate('draft-new', T0)
  expect(d.mode).toEqual({ kind: 'create' })
  expect(d.payload).toEqual(EMPTY_ZONE_CREATE_PAYLOAD)
  expect(d.payload.geometry).toEqual({ kind: 'polygon', vertices: [] })
  expect(isDirty(d)).toBe(false)
  expect(isDirty(patch(d, { name: 'Amber Belt' }, T1))).toBe(true)
  // authoring geometry — a gesture's ONLY write — flips dirty like any payload change
  expect(
    isDirty(
      patch(d, { geometry: { kind: 'circle', center: { x: 100, y: 100 }, radius: 250 } }, T1),
    ),
  ).toBe(true)
})

// ── projectFromLive: a live zone ALWAYS materializes to an editable polygon ─────────────────────────
test('projectFromLive materializes a polygon for every source — even source=circle rows — and drops the closing duplicate', () => {
  expect(ZONE_DRAFT_DESCRIPTOR.projectFromLive(zone())).toEqual({
    name: 'Crimson Reach',
    zone_kind: 'pirate',
    attach_location_id: null,
    geometry: {
      kind: 'polygon',
      vertices: [
        { x: 0, y: 0 },
        { x: 400, y: 0 },
        { x: 400, y: 400 },
        { x: 0, y: 400 },
      ],
    },
  })
  // a seeded 'circle' zone reads back as its materialized vertex ring — circle authoring is
  // CREATE-only seed geometry and never round-trips
  const circleZone = zone({ source: 'circle', location_id: 'loc-1' })
  const projected = ZONE_DRAFT_DESCRIPTOR.projectFromLive(circleZone)
  expect(projected.geometry.kind).toBe('polygon')
  expect(projected.attach_location_id).toBe('loc-1')
  // a null/absent ring projects to the honest empty polygon (validation flags it; nothing invented)
  expect(ZONE_DRAFT_DESCRIPTOR.projectFromLive(zone({ ring: null })).geometry).toEqual({
    kind: 'polygon',
    vertices: [],
  })
  // an UNCLOSED ring (defensive) is taken verbatim — only a true closing duplicate is dropped
  expect(
    ZONE_DRAFT_DESCRIPTOR.projectFromLive(
      zone({ ring: [[0, 0], [400, 0], [400, 400]] }),
    ).geometry,
  ).toEqual({
    kind: 'polygon',
    vertices: [
      { x: 0, y: 0 },
      { x: 400, y: 0 },
      { x: 400, y: 400 },
    ],
  })
})

// ── fingerprint stability ────────────────────────────────────────────────────────────────────────────
test('fingerprint is stable across calls and extra properties, and moves on any payload field change', () => {
  const p = ZONE_DRAFT_DESCRIPTOR.projectFromLive(zone())
  expect(computeSourceFingerprint(p)).toBe(computeSourceFingerprint({ ...p }))
  // extra non-payload properties are ignored
  expect(computeSourceFingerprint({ ...p, extra: 'ignored' } as typeof p)).toBe(
    computeSourceFingerprint(p),
  )
  // every payload field participates — geometry included
  expect(computeSourceFingerprint({ ...p, name: 'X' })).not.toBe(computeSourceFingerprint(p))
  expect(computeSourceFingerprint({ ...p, attach_location_id: 'loc-9' })).not.toBe(
    computeSourceFingerprint(p),
  )
  expect(
    computeSourceFingerprint({
      ...p,
      geometry: { kind: 'circle', center: { x: 0, y: 0 }, radius: 100 },
    }),
  ).not.toBe(computeSourceFingerprint(p))
})

// ── source status: current / changed / missing ───────────────────────────────────────────────────────
test('draftSourceStatus: current when live matches the forked revision; changed when the ring moved; missing when gone', () => {
  const d = forkEdit(zone(), 'draft-a', T0)
  expect(draftSourceStatus(d, zone())).toBe('current')
  expect(
    draftSourceStatus(d, zone({ ring: [[0, 0], [999, 0], [400, 400], [0, 400], [0, 0]] })),
  ).toBe('source_changed')
  expect(draftSourceStatus(d, undefined)).toBe('source_missing')
  // a create draft has no source — always current
  expect(draftSourceStatus(beginCreate('draft-new', T0), undefined)).toBe('current')
})

// ── bounds: FLAGGED, never clamped, never thrown ─────────────────────────────────────────────────────
test('polygon bounds: every vertex must pass the ONE shared predicate — values stay intact (no clamp, no throw)', () => {
  const inside = patch(
    beginCreate('d', T0),
    {
      geometry: {
        kind: 'polygon',
        vertices: [
          { x: -10_000, y: -10_000 },
          { x: 10_000, y: 0 },
          { x: 0, y: 10_000 },
        ],
      },
    },
    T1,
  )
  expect(validateDraftBounds(inside.payload)).toBe(true) // closed domain boundary is inside

  const far = patch(
    inside,
    {
      geometry: {
        kind: 'polygon',
        vertices: [
          { x: 0, y: 0 },
          { x: 20_000, y: 0 },
          { x: 0, y: 400 },
        ],
      },
    },
    T1,
  )
  expect(validateDraftBounds(far.payload)).toBe(false)
  if (far.payload.geometry.kind !== 'polygon') throw new Error('unreachable')
  expect(far.payload.geometry.vertices[1].x).toBe(20_000) // NOT snapped to the edge

  // the empty in-progress polygon has no out-of-bounds vertex (vertex-count is a validation flag)
  expect(validateDraftBounds(beginCreate('d2', T0).payload)).toBe(true)
})

test('circle bounds: in-bounds center + finite radius>0 + full extent within the domain', () => {
  const circle = (center: { x: number; y: number }, radius: number) =>
    patch(beginCreate('d', T0), { geometry: { kind: 'circle', center, radius } }, T1).payload
  expect(validateDraftBounds(circle({ x: 0, y: 0 }, 500))).toBe(true)
  expect(validateDraftBounds(circle({ x: 9_500, y: 0 }, 500))).toBe(true) // extent exactly at the edge
  expect(validateDraftBounds(circle({ x: 9_950, y: 0 }, 100))).toBe(false) // extent 10_050 leaks out
  expect(validateDraftBounds(circle({ x: 0, y: 0 }, 0))).toBe(false) // radius must be > 0
  expect(validateDraftBounds(circle({ x: 0, y: 0 }, -5))).toBe(false)
  expect(validateDraftBounds(circle({ x: 0, y: 0 }, Number.NaN))).toBe(false)
  expect(validateDraftBounds(circle({ x: Number.NaN, y: 0 }, 100))).toBe(false)
})

// ── preview shape parity with the live zone layer (geometry → representation 1:1) ───────────────────
test('draftToLayerItem has EXACTLY the LayerItem shape zoneLayerAdapter.readItems produces, for both geometries', () => {
  const DATA: WorldEditorData = { locations: [], zoneRefs: [], miningFields: [], explorationSites: [], zones: [zone()], miningExtractRadius: null, explorationScanRadius: null }
  const liveItem = zoneLayerAdapter.readItems(DATA)[0]
  const polygonItem = draftToLayerItem(forkEdit(zone(), 'draft-a', T0))

  // identical key set → the preview is structurally interchangeable with a live layer item
  expect(Object.keys(polygonItem).sort()).toEqual(Object.keys(liveItem).sort())
  expect(polygonItem.layer).toBe('zones')
  expect(polygonItem.id).toBe('draft-a')
  expect(polygonItem.representation).toEqual({
    kind: 'polygon',
    ring: [
      { x: 0, y: 0 },
      { x: 400, y: 0 },
      { x: 400, y: 400 },
      { x: 0, y: 400 },
    ],
  })
  // the hand-authored zone tone — the SAME token the live 'drawn' zone renders with
  expect(polygonItem.tone).toBe('var(--color-warning)')
  expect(liveItem.tone).toBe('var(--color-warning)')

  // a circle draft maps 1:1 onto the circle representation (PR-1's MapRepresentation form)
  const circleItem = draftToLayerItem(
    patch(
      beginCreate('draft-c', T0),
      { geometry: { kind: 'circle', center: { x: 250, y: -250 }, radius: 750 } },
      T1,
    ),
  )
  expect(circleItem.representation).toEqual({
    kind: 'circle',
    center: { x: 250, y: -250 },
    radius: 750,
  })

  // an unnamed create draft still renders an honest label
  expect(draftToLayerItem(beginCreate('draft-new', T0)).label).toBe('New zone')
})

// ── stored-blob rehydration parsing (the nested geometry union is structurally guarded) ─────────────
test('parseStoredDraft round-trips a real draft and drops garbage — including malformed geometry — instead of throwing', () => {
  const d = patch(forkEdit(zone(), 'draft-a', T0), { name: 'Crimson Deep' }, T1)
  expect(parseStoredDraft(JSON.stringify(d))).toEqual(d)
  const c = patch(
    beginCreate('draft-new', T0),
    { geometry: { kind: 'circle', center: { x: 10, y: 20 }, radius: 300 } },
    T1,
  )
  expect(parseStoredDraft(JSON.stringify(c))).toEqual(c)

  expect(parseStoredDraft('not json at all')).toBeNull()
  expect(parseStoredDraft('null')).toBeNull()
  expect(parseStoredDraft('{}')).toBeNull()
  expect(parseStoredDraft(JSON.stringify({ ...d, payload: { name: 42 } }))).toBeNull()
  // geometry union violations are dropped whole
  const withGeometry = (geometry: unknown) =>
    JSON.stringify({ ...c, payload: { ...c.payload, geometry } })
  expect(parseStoredDraft(withGeometry(null))).toBeNull()
  expect(parseStoredDraft(withGeometry({ kind: 'blob' }))).toBeNull()
  expect(parseStoredDraft(withGeometry({ kind: 'circle', center: { x: 1 }, radius: 5 }))).toBeNull()
  expect(
    parseStoredDraft(withGeometry({ kind: 'circle', center: { x: 1, y: 2 }, radius: '5' })),
  ).toBeNull()
  expect(parseStoredDraft(withGeometry({ kind: 'polygon', vertices: 'nope' }))).toBeNull()
  expect(
    parseStoredDraft(withGeometry({ kind: 'polygon', vertices: [{ x: 1, y: 'two' }] })),
  ).toBeNull()
  expect(parseStoredDraft(JSON.stringify({ ...d, mode: { kind: 'publish' } }))).toBeNull()
})

// ── descriptor identity (the ONE binding stays distinct from the other domains) ─────────────────────
test('the zone descriptor keys its own storage namespace and identifies rows by the danger_zones uuid', () => {
  expect(ZONE_DRAFT_DESCRIPTOR.domainId).toBe('zones')
  expect(ZONE_DRAFT_DESCRIPTOR.storageKeyPrefix).toBe('byeharu.worldEditor.zoneDraft.v1:')
  expect(ZONE_DRAFT_DESCRIPTOR.liveId(zone())).toBe('a3d2b1c0-0000-4000-8000-000000000001')
  expect(ZONE_DRAFT_DESCRIPTOR.payloadKeys).toEqual([
    'name',
    'zone_kind',
    'attach_location_id',
    'geometry',
  ])
})

import { test, expect } from '@playwright/test'
import { beginCreate, forkEdit, patch } from '../src/features/worldeditor/zoneDraftModel'
import {
  ZONE_POLYGON_MAX_VERTICES,
  validateZoneDraft,
  type ZoneValidationContext,
} from '../src/features/worldeditor/zoneValidation'
import type {
  LiveDangerZone,
  ZoneDraft,
  ZoneGeometry,
} from '../src/features/worldeditor/zoneDraftTypes'

// WORLD EDITOR V3A PR-2 — pure proofs for the zone validator (advisory, flag-only), mirroring
// tests/miningValidation.spec.ts. Every rule: geometry bounds, circle radius, vertex count,
// degeneracy, self-intersection, name, duplicate/affected warnings, source freshness, conflicting
// drafts — and the publishable fold. Run: `npx playwright test zoneValidation.spec.ts`.

const T0 = 1_700_000_000_000
const T1 = T0 + 60_000

const SQUARE: ZoneGeometry = {
  kind: 'polygon',
  vertices: [
    { x: 0, y: 0 },
    { x: 500, y: 0 },
    { x: 500, y: 500 },
    { x: 0, y: 500 },
  ],
}

/** A valid create draft (named square) to perturb per rule. */
const draftWith = (over: { name?: string; geometry?: ZoneGeometry }): ZoneDraft =>
  patch(
    beginCreate('draft-a', T0),
    { name: over.name ?? 'Test Zone', geometry: over.geometry ?? SQUARE },
    T1,
  )

const ctx = (over: Partial<ZoneValidationContext> = {}): ZoneValidationContext => ({
  live: [],
  sourceStatus: 'current',
  otherDrafts: [],
  locations: [],
  ...over,
})

const liveZone = (over: Partial<LiveDangerZone> = {}): LiveDangerZone => ({
  id: 'z-1',
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

const codes = (d: ZoneDraft, c: ZoneValidationContext = ctx()) =>
  validateZoneDraft(d, c).issues.map((i) => i.code)

// ── the happy path ──────────────────────────────────────────────────────────────────────────────────
test('a named, in-bounds, simple polygon draft validates clean and publishable', () => {
  const report = validateZoneDraft(draftWith({}), ctx())
  expect(report.issues).toEqual([])
  expect(report.publishable).toBe(true)
})

// ── bounds ──────────────────────────────────────────────────────────────────────────────────────────
test('coord_out_of_bounds: an out-of-domain vertex is an ERROR — the value stays intact', () => {
  const d = draftWith({
    geometry: {
      kind: 'polygon',
      vertices: [
        { x: 0, y: 0 },
        { x: 20_000, y: 0 },
        { x: 0, y: 400 },
      ],
    },
  })
  const report = validateZoneDraft(d, ctx())
  const issue = report.issues.find((i) => i.code === 'coord_out_of_bounds')
  expect(issue?.severity).toBe('error')
  expect(report.publishable).toBe(false)
  if (d.payload.geometry.kind !== 'polygon') throw new Error('unreachable')
  expect(d.payload.geometry.vertices[1].x).toBe(20_000) // flagged, never clamped
})

test('coord_out_of_bounds: a circle whose EXTENT leaks past the domain is an ERROR even with an in-bounds center', () => {
  const d = draftWith({
    geometry: { kind: 'circle', center: { x: 9_950, y: 0 }, radius: 100 },
  })
  expect(codes(d)).toContain('coord_out_of_bounds')
  expect(codes(d)).not.toContain('radius_not_positive') // the radius itself is fine
  // a fitting circle raises neither
  const ok = draftWith({ geometry: { kind: 'circle', center: { x: 0, y: 0 }, radius: 750 } })
  expect(codes(ok)).toEqual([])
})

// ── circle radius ───────────────────────────────────────────────────────────────────────────────────
test('radius_not_positive: zero, negative and non-finite radii are ERRORS', () => {
  for (const radius of [0, -5, Number.NaN, Number.POSITIVE_INFINITY]) {
    const d = draftWith({ geometry: { kind: 'circle', center: { x: 0, y: 0 }, radius } })
    const report = validateZoneDraft(d, ctx())
    expect(report.issues.map((i) => i.code), `radius ${radius}`).toContain('radius_not_positive')
    expect(report.publishable).toBe(false)
  }
})

// ── polygon vertex count ────────────────────────────────────────────────────────────────────────────
test('polygon_too_few_vertices: fewer than 3 vertices is an ERROR (the in-progress drawing state)', () => {
  const d = draftWith({
    geometry: { kind: 'polygon', vertices: [{ x: 0, y: 0 }, { x: 100, y: 0 }] },
  })
  expect(codes(d)).toContain('polygon_too_few_vertices')
  expect(codes(draftWith({ geometry: { kind: 'polygon', vertices: [] } }))).toContain(
    'polygon_too_few_vertices',
  )
})

test(`polygon_too_many_vertices: more than ${ZONE_POLYGON_MAX_VERTICES} vertices is an ERROR`, () => {
  const n = ZONE_POLYGON_MAX_VERTICES + 1
  const ring = Array.from({ length: n }, (_, i) => {
    const a = (2 * Math.PI * i) / n
    return { x: Math.round(1000 * Math.cos(a)), y: Math.round(1000 * Math.sin(a)) }
  })
  const d = draftWith({ geometry: { kind: 'polygon', vertices: ring } })
  expect(codes(d)).toContain('polygon_too_many_vertices')
  // exactly the ceiling is fine
  const atMax = ring.slice(0, ZONE_POLYGON_MAX_VERTICES)
  expect(codes(draftWith({ geometry: { kind: 'polygon', vertices: atMax } }))).toEqual([])
})

// ── degeneracy + self-intersection (the ONE zone geometry authority decides) ────────────────────────
test('degenerate_polygon: collinear vertices enclose no area — ERROR', () => {
  const d = draftWith({
    geometry: {
      kind: 'polygon',
      vertices: [
        { x: 0, y: 0 },
        { x: 100, y: 100 },
        { x: 200, y: 200 },
      ],
    },
  })
  expect(codes(d)).toContain('degenerate_polygon')
})

test('self_intersection: the bowtie is an ERROR; the untangled square is not', () => {
  const bowtie = draftWith({
    geometry: {
      kind: 'polygon',
      vertices: [
        { x: 0, y: 0 },
        { x: 100, y: 100 },
        { x: 100, y: 0 },
        { x: 0, y: 100 },
      ],
    },
  })
  const report = validateZoneDraft(bowtie, ctx())
  expect(report.issues.map((i) => i.code)).toContain('self_intersection')
  expect(report.publishable).toBe(false)
  expect(codes(draftWith({}))).not.toContain('self_intersection')
})

// ── name rules ──────────────────────────────────────────────────────────────────────────────────────
test('name_required: empty and all-whitespace names are ERRORS', () => {
  expect(codes(draftWith({ name: '' }))).toContain('name_required')
  expect(codes(draftWith({ name: '   ' }))).toContain('name_required')
})

test('duplicate_name: a live-zone name clash is a WARNING (no unique constraint) and an edit draft ignores its own source', () => {
  const d = draftWith({ name: 'crimson reach' }) // case-insensitive
  const report = validateZoneDraft(d, ctx({ live: [liveZone()] }))
  const issue = report.issues.find((i) => i.code === 'duplicate_name')
  expect(issue?.severity).toBe('warning')
  expect(report.publishable).toBe(true) // warnings never block

  // the edit fork of that very zone does NOT warn about itself
  const edit = forkEdit(liveZone(), 'draft-e', T0)
  expect(codes(edit, ctx({ live: [liveZone()] }))).not.toContain('duplicate_name')
})

// ── affected locations (advisory containment — "who this zone endangers") ───────────────────────────
test('affected_locations: locations inside the polygon or circle surface as ONE aggregated WARNING', () => {
  const locations = [
    { id: 'l1', name: 'Port Alpha', x: 100, y: 100 }, // inside the square
    { id: 'l2', name: 'Port Beta', x: 9_000, y: 9_000 }, // far outside
  ]
  const polyReport = validateZoneDraft(draftWith({}), ctx({ locations }))
  const polyIssue = polyReport.issues.find((i) => i.code === 'affected_locations')
  expect(polyIssue?.severity).toBe('warning')
  expect(polyIssue?.message).toContain('Port Alpha')
  expect(polyIssue?.message).not.toContain('Port Beta')

  const circleDraft = draftWith({
    geometry: { kind: 'circle', center: { x: 0, y: 0 }, radius: 200 },
  })
  expect(codes(circleDraft, ctx({ locations }))).toContain('affected_locations')

  // nothing inside → no advisory
  const offset = draftWith({
    geometry: { kind: 'circle', center: { x: -5_000, y: -5_000 }, radius: 100 },
  })
  expect(codes(offset, ctx({ locations }))).not.toContain('affected_locations')
})

// ── source freshness + conflicting drafts ───────────────────────────────────────────────────────────
test('source_changed is a WARNING; source_missing is an ERROR (unpublishable edit)', () => {
  const edit = forkEdit(liveZone(), 'draft-e', T0)
  const changed = validateZoneDraft(edit, ctx({ live: [liveZone()], sourceStatus: 'source_changed' }))
  expect(changed.issues.find((i) => i.code === 'source_changed')?.severity).toBe('warning')
  expect(changed.publishable).toBe(true)

  const missing = validateZoneDraft(edit, ctx({ sourceStatus: 'source_missing' }))
  expect(missing.issues.find((i) => i.code === 'source_missing')?.severity).toBe('error')
  expect(missing.publishable).toBe(false)
})

test('conflicting_draft: another edit of the same live row, or another create with the same name — WARNINGS', () => {
  const editA = forkEdit(liveZone(), 'draft-a', T0)
  const editB = forkEdit(liveZone(), 'draft-b', T0)
  expect(codes(editA, ctx({ live: [liveZone()], otherDrafts: [editB] }))).toContain(
    'conflicting_draft',
  )

  const createA = draftWith({ name: 'Twin Zone' })
  const createB = patch(beginCreate('draft-c', T0), { name: 'twin zone', geometry: SQUARE }, T1)
  expect(codes(createA, ctx({ otherDrafts: [createB] }))).toContain('conflicting_draft')
  expect(codes(createA, ctx({ otherDrafts: [] }))).not.toContain('conflicting_draft')
})

// ── the publishable fold ────────────────────────────────────────────────────────────────────────────
test('publishable is true under warnings only and flips false the moment any ERROR appears', () => {
  // warnings only (duplicate live name) → still publishable
  const warned = validateZoneDraft(
    draftWith({ name: 'Crimson Reach' }),
    ctx({ live: [liveZone()] }),
  )
  expect(warned.issues.length).toBeGreaterThan(0)
  expect(warned.issues.every((i) => i.severity === 'warning')).toBe(true)
  expect(warned.publishable).toBe(true)

  // add an error (empty name) → unpublishable
  const errored = validateZoneDraft(draftWith({ name: '' }), ctx({ live: [liveZone()] }))
  expect(errored.publishable).toBe(false)
})

import { test, expect } from '@playwright/test'
import {
  MINING_FIELD_OVERLAP_RADIUS_FALLBACK,
  validateMiningDraft,
  type MiningValidationCode,
  type MiningValidationContext,
  type MiningValidationReport,
} from '../src/features/worldeditor/miningValidation'
import type { MiningDraft, MiningDraftPayload } from '../src/features/worldeditor/miningDraftTypes'
import type { MiningField } from '../src/features/mining/miningTypes'
import { beginCreate, forkEdit, patch } from '../src/features/worldeditor/miningDraftModel'

// WORLD EDITOR V2A PR-2 — pure per-rule proofs for the mining-draft validator (built on the generic
// draftValidation contract), mirroring tests/locationValidation.spec.ts. No browser/DB: the
// validator is deterministic (draft + context in → report out). Run:
// `npx playwright test miningValidation.spec.ts`.

const T0 = 0

const field = (over: Partial<MiningField> = {}): MiningField => ({
  name: 'Ferrite Shoal',
  space_x: 5000,
  space_y: 5000,
  ...over,
})

/** A clean CREATE draft: named, in bounds, with a valid local reward bundle. */
const createDraft = (over: Partial<MiningDraftPayload> = {}): MiningDraft =>
  patch(
    beginCreate('draft-a', T0),
    {
      name: 'Amber Vein',
      space_x: 0,
      space_y: 0,
      reward_bundle_json: { items: [{ item_id: 'ore_iron', quantity: 3 }] },
      ...over,
    },
    T0 + 1,
  )

const ctx = (over: Partial<MiningValidationContext> = {}): MiningValidationContext => ({
  live: [],
  sourceStatus: 'current',
  otherDrafts: [],
  ...over,
})

const codes = (r: MiningValidationReport): MiningValidationCode[] => r.issues.map((i) => i.code)
const severityOf = (r: MiningValidationReport, code: MiningValidationCode) =>
  r.issues.find((i) => i.code === code)?.severity

// ── baseline ────────────────────────────────────────────────────────────────────────────────────────
test('a clean create draft (named, in bounds, valid bundle) validates with zero issues and is publishable', () => {
  const r = validateMiningDraft(createDraft(), ctx())
  expect(r.issues).toEqual([])
  expect(r.publishable).toBe(true)
})

// ── coordinate bounds (shared predicate; closed domain; flag-only) ──────────────────────────────────
test('coord bounds: ±10000 is inside (closed domain); 10000.0001 is out; both axes checked', () => {
  expect(codes(validateMiningDraft(createDraft({ space_x: 10_000, space_y: -10_000 }), ctx()))).toEqual([])
  expect(codes(validateMiningDraft(createDraft({ space_x: -10_000, space_y: 10_000 }), ctx()))).toEqual([])

  const out = validateMiningDraft(createDraft({ space_x: 10_000.0001 }), ctx())
  expect(codes(out)).toContain('coord_out_of_bounds')
  expect(severityOf(out, 'coord_out_of_bounds')).toBe('error')
  expect(out.publishable).toBe(false)

  expect(codes(validateMiningDraft(createDraft({ space_y: -10_000.0001 }), ctx()))).toContain(
    'coord_out_of_bounds',
  )
})

test('non-finite coordinates: NaN / Infinity produce per-field numeric_not_finite errors (and fail bounds)', () => {
  const r = validateMiningDraft(
    createDraft({ space_x: Number.NaN, space_y: Number.POSITIVE_INFINITY }),
    ctx(),
  )
  const finiteIssues = r.issues.filter((i) => i.code === 'numeric_not_finite')
  expect(finiteIssues.map((i) => i.field).sort()).toEqual(['space_x', 'space_y'])
  expect(finiteIssues.every((i) => i.severity === 'error')).toBe(true)
  expect(codes(r)).toContain('coord_out_of_bounds')
  expect(r.publishable).toBe(false)
})

// ── name rules (mining_fields.name is NOT NULL + the unique natural key) ────────────────────────────
test('name: empty and whitespace-only are name_required errors', () => {
  for (const name of ['', '   ', '\t']) {
    const r = validateMiningDraft(createDraft({ name }), ctx())
    expect(codes(r)).toContain('name_required')
    expect(severityOf(r, 'name_required')).toBe('error')
    expect(r.publishable).toBe(false)
  }
})

test('duplicate_name: case-insensitive scan of live ACTIVE fields is a WARNING; an edit ignores its own row', () => {
  // WARNING (not error): the client only sees active fields — a hidden-field clash is invisible,
  // so the server's unique key stays the authority.
  const c = ctx({ live: [field({ name: 'Ferrite Shoal' })] })
  const r = validateMiningDraft(createDraft({ name: 'ferrite shoal' }), c)
  expect(codes(r)).toEqual(['duplicate_name'])
  expect(severityOf(r, 'duplicate_name')).toBe('warning')
  expect(r.publishable).toBe(true)

  // an unmodified edit draft of that very row must NOT flag itself (bundle-null edits warn nothing)
  const d = forkEdit(field({ name: 'Ferrite Shoal' }), 'draft-a', T0)
  const rEdit = validateMiningDraft(d, ctx({ live: [field({ name: 'Ferrite Shoal' })] }))
  expect(codes(rEdit)).toEqual([])
})

// ── reward bundle (CREATE-only local field; ONE shared pending-bundle shape) ────────────────────────
test('reward bundle: a valid { items: [{ item_id, quantity }] } bundle raises nothing', () => {
  const r = validateMiningDraft(
    createDraft({ reward_bundle_json: { metal: 10, items: [{ item_id: 'ore_iron', quantity: 1 }] } }),
    ctx(),
  )
  expect(r.issues).toEqual([])
})

test('reward bundle: empty items[] (or missing items) is a reward_bundle_invalid ERROR', () => {
  const empty = validateMiningDraft(createDraft({ reward_bundle_json: { items: [] } }), ctx())
  expect(codes(empty)).toEqual(['reward_bundle_invalid'])
  expect(severityOf(empty, 'reward_bundle_invalid')).toBe('error')
  expect(empty.publishable).toBe(false)

  const missing = validateMiningDraft(createDraft({ reward_bundle_json: { metal: 5 } }), ctx())
  expect(codes(missing)).toEqual(['reward_bundle_invalid'])
  expect(missing.publishable).toBe(false)
})

test('reward bundle: bad quantities (0 / negative / non-integer / NaN) and empty item_id are ERRORS', () => {
  for (const quantity of [0, -2, 1.5, Number.NaN]) {
    const r = validateMiningDraft(
      createDraft({ reward_bundle_json: { items: [{ item_id: 'ore_iron', quantity }] } }),
      ctx(),
    )
    expect(codes(r), `quantity ${quantity}`).toEqual(['reward_bundle_invalid'])
    expect(r.publishable).toBe(false)
  }
  const badId = validateMiningDraft(
    createDraft({ reward_bundle_json: { items: [{ item_id: '   ', quantity: 1 }] } }),
    ctx(),
  )
  expect(codes(badId)).toEqual(['reward_bundle_invalid'])
  expect(badId.publishable).toBe(false)
})

test('reward bundle: null on a CREATE is a WARNING (no reward configured) — still publishable; null on an EDIT raises nothing', () => {
  const rCreate = validateMiningDraft(createDraft({ reward_bundle_json: null }), ctx())
  expect(codes(rCreate)).toEqual(['reward_bundle_missing'])
  expect(severityOf(rCreate, 'reward_bundle_missing')).toBe('warning')
  expect(rCreate.publishable).toBe(true)

  // an edit fork's bundle is ALWAYS null (never readable from live) — that must not warn
  const d = forkEdit(field(), 'draft-a', T0)
  expect(d.payload.reward_bundle_json).toBeNull()
  expect(codes(validateMiningDraft(d, ctx({ live: [field()] })))).toEqual([])
})

// ── field overlap (ONE shared distance formula; touching is NOT overlap) ────────────────────────────
test('field_overlap: d < mining_extract_radius warns; d == radius does not; an edit ignores its own row', () => {
  expect(MINING_FIELD_OVERLAP_RADIUS_FALLBACK).toBe(750)

  // exactly at the radius → NOT an overlap
  const touching = ctx({ live: [field({ space_x: MINING_FIELD_OVERLAP_RADIUS_FALLBACK, space_y: 0 })] })
  expect(codes(validateMiningDraft(createDraft({ space_x: 0, space_y: 0 }), touching))).toEqual([])

  // strictly inside the radius → WARNING
  const near = ctx({ live: [field({ space_x: MINING_FIELD_OVERLAP_RADIUS_FALLBACK - 1, space_y: 0 })] })
  const r = validateMiningDraft(createDraft({ space_x: 0, space_y: 0 }), near)
  expect(codes(r)).toEqual(['field_overlap'])
  expect(severityOf(r, 'field_overlap')).toBe('warning')
  expect(r.publishable).toBe(true)

  // an edit draft ignores its own source row (distance 0 to itself is not an overlap)
  const src = field()
  const d = forkEdit(src, 'draft-a', T0)
  expect(codes(validateMiningDraft(d, ctx({ live: [src] })))).toEqual([])
})

// ── C1: the radius arrives FROM CONTEXT (server-authoritative); 750 is only the labeled fallback ────
test('field_overlap radius: ctx.overlapRadius (game_config) overrides the 750 fallback; absent/invalid context falls back', () => {
  const at400 = () => createDraft({ space_x: 0, space_y: 0 })
  const live400 = [field({ space_x: 400, space_y: 0 })]

  // server radius 300: distance 400 is OUTSIDE → no overlap (would warn under the 750 fallback)
  expect(codes(validateMiningDraft(at400(), ctx({ live: live400, overlapRadius: 300 })))).toEqual([])

  // server radius 500: distance 400 is INSIDE → warning
  const wide = validateMiningDraft(at400(), ctx({ live: live400, overlapRadius: 500 }))
  expect(codes(wide)).toEqual(['field_overlap'])
  expect(severityOf(wide, 'field_overlap')).toBe('warning')

  // absent (undefined), null, and invalid (0 / NaN) all fall back to the labeled 750 default
  for (const overlapRadius of [undefined, null, 0, Number.NaN]) {
    const r = validateMiningDraft(at400(), ctx({ live: live400, overlapRadius }))
    expect(codes(r), `overlapRadius ${String(overlapRadius)}`).toEqual(['field_overlap'])
  }
})

// ── stale source (store-computed sourceStatus surfaced honestly) ────────────────────────────────────
test('source freshness: source_changed is a WARNING; source_missing is an ERROR (unpublishable)', () => {
  const changed = validateMiningDraft(createDraft(), ctx({ sourceStatus: 'source_changed' }))
  expect(codes(changed)).toEqual(['source_changed'])
  expect(severityOf(changed, 'source_changed')).toBe('warning')
  expect(changed.publishable).toBe(true)

  const missing = validateMiningDraft(createDraft(), ctx({ sourceStatus: 'source_missing' }))
  expect(codes(missing)).toEqual(['source_missing'])
  expect(severityOf(missing, 'source_missing')).toBe('error')
  expect(missing.publishable).toBe(false)
})

// ── conflicting drafts (local coordination WARNING) ─────────────────────────────────────────────────
test('conflicting_draft: another edit of the same live row (edit), or a same-named draft (create)', () => {
  const src = field()
  const mine = forkEdit(src, 'draft-a', T0)
  const other = forkEdit(src, 'draft-b', T0)
  const rEdit = validateMiningDraft(mine, ctx({ live: [src], otherDrafts: [other] }))
  expect(codes(rEdit)).toEqual(['conflicting_draft'])
  expect(severityOf(rEdit, 'conflicting_draft')).toBe('warning')

  const otherCreate = patch(beginCreate('draft-c', T0), { name: 'amber vein' }, T0 + 1)
  const rCreate = validateMiningDraft(createDraft({ name: 'Amber Vein' }), ctx({ otherDrafts: [otherCreate] }))
  expect(codes(rCreate)).toEqual(['conflicting_draft'])

  // disjoint targets → no conflict
  expect(
    codes(validateMiningDraft(createDraft(), ctx({ otherDrafts: [beginCreate('d', T0)] }))),
  ).toEqual([])
})

// ── publishable semantics ───────────────────────────────────────────────────────────────────────────
test('publishable flips ONLY on error severity: warnings alone stay publishable', () => {
  // warnings only: duplicate name + overlap + stale-changed + no bundle
  const warnOnly = validateMiningDraft(
    createDraft({ name: 'Ferrite Shoal', space_x: 5100, space_y: 5000, reward_bundle_json: null }),
    ctx({ live: [field({ name: 'ferrite shoal' })], sourceStatus: 'source_changed' }),
  )
  expect(warnOnly.issues.length).toBeGreaterThanOrEqual(4)
  expect(warnOnly.issues.every((i) => i.severity === 'warning')).toBe(true)
  expect(warnOnly.publishable).toBe(true)

  // add ONE error on top → unpublishable
  const withError = validateMiningDraft(
    createDraft({ name: 'Ferrite Shoal', space_x: 20_000, space_y: 5000, reward_bundle_json: null }),
    ctx({ live: [field({ name: 'ferrite shoal' })], sourceStatus: 'source_changed' }),
  )
  expect(withError.issues.some((i) => i.severity === 'error')).toBe(true)
  expect(withError.publishable).toBe(false)
})

// ── determinism + flag-only (the location-validator guards, applied to the mining domain) ───────────
test('determinism and no clamping: repeat runs deep-equal; out-of-domain values keep their EXACT values', () => {
  const messy = (): MiningDraft =>
    createDraft({ space_x: 20_000, space_y: -30_000, reward_bundle_json: { items: [] } })
  const c = () =>
    ctx({ live: [field()], sourceStatus: 'source_changed', otherDrafts: [forkEdit(field(), 'o', T0)] })
  expect(validateMiningDraft(messy(), c())).toEqual(validateMiningDraft(messy(), c()))

  const d = messy()
  const report = validateMiningDraft(d, c())
  expect(report.issues.map((i) => i.code)).toContain('coord_out_of_bounds')
  expect(d.payload.space_x).toBe(20_000) // NOT snapped to the edge
  expect(d.payload.space_y).toBe(-30_000)
  expect(d.payload.reward_bundle_json).toEqual({ items: [] }) // not rewritten/dropped
})

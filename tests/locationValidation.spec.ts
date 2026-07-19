import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  validateLocationDraft,
  type ValidationCode,
  type ValidationContext,
  type ValidationReport,
} from '../src/features/worldeditor/locationValidation'
import {
  ACTIVITY_TYPES,
  LOCATION_STATUSES,
  LOCATION_TYPES,
} from '../src/features/worldeditor/locationEnums'
import type {
  ActivityType,
  LocationType,
  MapLocation,
} from '../src/features/map/mapTypes'
import type { LocationDraft, LocationDraftPayload } from '../src/features/worldeditor/locationDraftTypes'
import { beginCreate, forkEdit, patch } from '../src/features/worldeditor/locationDraftModel'

// WORLD EDITOR V1B-2 — pure per-rule proofs for the location-draft validator. No browser/DB: the
// validator is deterministic (payload + context in → report out). Run:
// `npx playwright test locationValidation.spec.ts`.

const payload = (over: Partial<LocationDraftPayload> = {}): LocationDraftPayload => ({
  name: 'Amber',
  location_type: 'safe_zone',
  activity_type: 'none',
  x: 0,
  y: 0,
  reward_tier: 0,
  base_difficulty: 0,
  min_power_required: 0,
  is_public: true,
  territory_radius: null,
  status: 'active',
  ...over,
})

const live = (over: Partial<MapLocation> = {}): MapLocation => ({
  id: 'loc-1',
  name: 'Aurelia',
  location_type: 'trade_outpost',
  x: 5000,
  y: 5000,
  base_difficulty: 5,
  reward_tier: 3,
  activity_type: 'trade_visit',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  territory_radius: null,
  ...over,
})

const ctx = (over: Partial<ValidationContext> = {}): ValidationContext => ({
  liveLocations: [],
  sourceStatus: 'current',
  draftMode: { kind: 'create' },
  otherDrafts: [],
  ...over,
})

const codes = (r: ValidationReport): ValidationCode[] => r.issues.map((i) => i.code)
const severityOf = (r: ValidationReport, code: ValidationCode) =>
  r.issues.find((i) => i.code === code)?.severity

// ── baseline ────────────────────────────────────────────────────────────────────────────────────────
test('a clean create payload validates with zero issues and is publishable', () => {
  const r = validateLocationDraft(payload(), ctx())
  expect(r.issues).toEqual([])
  expect(r.publishable).toBe(true)
})

// ── coordinate bounds (shared predicate; closed domain; flag-only) ──────────────────────────────────
test('coord bounds: ±10000 is inside (closed domain); 10000.0001 is out; both axes checked', () => {
  expect(codes(validateLocationDraft(payload({ x: 10_000, y: -10_000 }), ctx()))).toEqual([])
  expect(codes(validateLocationDraft(payload({ x: -10_000, y: 10_000 }), ctx()))).toEqual([])

  const out = validateLocationDraft(payload({ x: 10_000.0001 }), ctx())
  expect(codes(out)).toContain('coord_out_of_bounds')
  expect(severityOf(out, 'coord_out_of_bounds')).toBe('error')
  expect(out.publishable).toBe(false)

  expect(codes(validateLocationDraft(payload({ y: -10_000.0001 }), ctx()))).toContain(
    'coord_out_of_bounds',
  )
})

test('non-finite coordinates: NaN / Infinity produce numeric_not_finite errors (and fail bounds)', () => {
  const r = validateLocationDraft(payload({ x: Number.NaN, y: Number.POSITIVE_INFINITY }), ctx())
  const finiteIssues = r.issues.filter((i) => i.code === 'numeric_not_finite')
  expect(finiteIssues.map((i) => i.field).sort()).toEqual(['x', 'y'])
  expect(finiteIssues.every((i) => i.severity === 'error')).toBe(true)
  expect(codes(r)).toContain('coord_out_of_bounds')
  expect(r.publishable).toBe(false)
})

// ── name rules ──────────────────────────────────────────────────────────────────────────────────────
test('name: empty and whitespace-only are name_required errors', () => {
  for (const name of ['', '   ', '\t']) {
    const r = validateLocationDraft(payload({ name }), ctx())
    expect(codes(r)).toContain('name_required')
    expect(severityOf(r, 'name_required')).toBe('error')
    expect(r.publishable).toBe(false)
  }
})

test('name: a multi-word name is a WARNING (convention), never an error — still publishable', () => {
  const r = validateLocationDraft(payload({ name: 'Amber Shoal' }), ctx())
  expect(codes(r)).toEqual(['name_not_single_word'])
  expect(severityOf(r, 'name_not_single_word')).toBe('warning')
  expect(r.publishable).toBe(true)
})

// ── CHECK-enum membership ───────────────────────────────────────────────────────────────────────────
test('enum membership: each invalid literal is its own error', () => {
  const badType = validateLocationDraft(
    payload({ location_type: 'volcano' as LocationType }),
    ctx(),
  )
  expect(codes(badType)).toEqual(['invalid_location_type'])
  expect(badType.publishable).toBe(false)

  const badActivity = validateLocationDraft(
    payload({ activity_type: 'dance' as ActivityType }),
    ctx(),
  )
  expect(codes(badActivity)).toEqual(['invalid_activity_type'])
  expect(badActivity.publishable).toBe(false)

  const badStatus = validateLocationDraft(payload({ status: 'archived' }), ctx())
  expect(codes(badStatus)).toEqual(['invalid_status'])
  expect(badStatus.publishable).toBe(false)

  // every member of the runtime authority passes
  for (const t of LOCATION_TYPES)
    expect(codes(validateLocationDraft(payload({ location_type: t }), ctx()))).toEqual([])
  for (const a of ACTIVITY_TYPES)
    expect(codes(validateLocationDraft(payload({ activity_type: a }), ctx()))).toEqual([])
  for (const s of LOCATION_STATUSES)
    expect(codes(validateLocationDraft(payload({ status: s }), ctx()))).toEqual([])
})

// ── numeric domains (mirroring the live CHECKs) ─────────────────────────────────────────────────────
test('reward_tier: 0 ok; -1 negative error; 1.5 non-integer error; NaN only numeric_not_finite', () => {
  expect(codes(validateLocationDraft(payload({ reward_tier: 0 }), ctx()))).toEqual([])
  expect(codes(validateLocationDraft(payload({ reward_tier: -1 }), ctx()))).toEqual([
    'reward_tier_negative',
  ])
  expect(codes(validateLocationDraft(payload({ reward_tier: 1.5 }), ctx()))).toEqual([
    'reward_tier_not_integer',
  ])
  // non-finite short-circuits the domain checks — one honest issue, no misleading cascade
  expect(codes(validateLocationDraft(payload({ reward_tier: Number.NaN }), ctx()))).toEqual([
    'numeric_not_finite',
  ])
})

test('base_difficulty and min_power_required: >= 0 enforced as errors', () => {
  expect(codes(validateLocationDraft(payload({ base_difficulty: -0.5 }), ctx()))).toEqual([
    'base_difficulty_negative',
  ])
  expect(codes(validateLocationDraft(payload({ min_power_required: -5 }), ctx()))).toEqual([
    'min_power_negative',
  ])
  expect(codes(validateLocationDraft(payload({ base_difficulty: 3, min_power_required: 10 }), ctx()))).toEqual([])
})

test('territory_radius: null ok (no territory); 0 and negative fail; positive ok; Infinity non-finite', () => {
  expect(codes(validateLocationDraft(payload({ territory_radius: null }), ctx()))).toEqual([])
  expect(codes(validateLocationDraft(payload({ territory_radius: 0 }), ctx()))).toEqual([
    'territory_radius_not_positive',
  ])
  expect(codes(validateLocationDraft(payload({ territory_radius: -10 }), ctx()))).toEqual([
    'territory_radius_not_positive',
  ])
  expect(codes(validateLocationDraft(payload({ territory_radius: 400 }), ctx()))).toEqual([])
  expect(
    codes(validateLocationDraft(payload({ territory_radius: Number.POSITIVE_INFINITY }), ctx())),
  ).toEqual(['numeric_not_finite'])
})

// ── duplicate name vs live world (server-only-decidable → WARNING) ──────────────────────────────────
test('duplicate_name: case-insensitive world-wide scan is a WARNING; an edit ignores its own source row', () => {
  const c = ctx({ liveLocations: [live({ name: 'Aurelia' })] })
  const r = validateLocationDraft(payload({ name: 'aurelia' }), c)
  expect(codes(r)).toEqual(['duplicate_name'])
  expect(severityOf(r, 'duplicate_name')).toBe('warning')
  expect(r.publishable).toBe(true)

  // an unmodified edit draft of that very row must NOT flag itself
  const d = forkEdit(live({ name: 'Aurelia' }), 'draft-a', 0)
  const rEdit = validateLocationDraft(d.payload, ctx({ liveLocations: [live()], draftMode: d.mode }))
  expect(codes(rEdit)).toEqual([])
})

// ── territory overlap (shared distance; touching is NOT overlap) ────────────────────────────────────
test('territory_overlap: d < r1+r2 warns; touching circles (d == r1+r2) do not; radius-less live rows ignored', () => {
  const draftP = payload({ x: 0, y: 0, territory_radius: 100 })

  // touching: live at (200,0) with r=100 → d == 200 == 100+100 → NOT an overlap
  const touching = ctx({ liveLocations: [live({ x: 200, y: 0, territory_radius: 100 })] })
  expect(codes(validateLocationDraft(draftP, touching))).toEqual([])

  // strictly inside the combined radius → WARNING
  const overlapping = ctx({ liveLocations: [live({ x: 199, y: 0, territory_radius: 100 })] })
  const r = validateLocationDraft(draftP, overlapping)
  expect(codes(r)).toEqual(['territory_overlap'])
  expect(severityOf(r, 'territory_overlap')).toBe('warning')
  expect(r.publishable).toBe(true)

  // a live location that projects no territory can never overlap
  const noTerritory = ctx({ liveLocations: [live({ x: 1, y: 0, territory_radius: null })] })
  expect(codes(validateLocationDraft(draftP, noTerritory))).toEqual([])

  // an edit draft ignores its own source row's territory
  const src = live({ x: 0, y: 0, territory_radius: 100 })
  const d = forkEdit(src, 'draft-a', 0)
  expect(
    codes(validateLocationDraft(d.payload, ctx({ liveLocations: [src], draftMode: d.mode }))),
  ).toEqual([])
})

// ── status transition (edit-only, visibility-loss WARNING) ──────────────────────────────────────────
test('status_transition_risky: active → locked/hidden on an EDIT warns; creates and non-active sources do not', () => {
  const srcActive = live({ status: 'active' })
  const d = patch(forkEdit(srcActive, 'draft-a', 0), { status: 'hidden' }, 1)
  const r = validateLocationDraft(d.payload, ctx({ liveLocations: [srcActive], draftMode: d.mode }))
  expect(codes(r)).toEqual(['status_transition_risky'])
  expect(severityOf(r, 'status_transition_risky')).toBe('warning')
  expect(r.publishable).toBe(true)

  const dLocked = patch(forkEdit(srcActive, 'draft-b', 0), { status: 'locked' }, 1)
  expect(
    codes(validateLocationDraft(dLocked.payload, ctx({ liveLocations: [srcActive], draftMode: dLocked.mode }))),
  ).toContain('status_transition_risky')

  // a CREATE draft with status 'hidden' is not a transition (nothing was visible)
  expect(codes(validateLocationDraft(payload({ status: 'hidden' }), ctx()))).toEqual([])

  // a locked → hidden edit is not the risky active → non-active transition
  const srcLocked = live({ id: 'loc-2', status: 'locked' })
  const d2 = patch(forkEdit(srcLocked, 'draft-c', 0), { status: 'hidden' }, 1)
  expect(
    codes(validateLocationDraft(d2.payload, ctx({ liveLocations: [srcLocked], draftMode: d2.mode }))),
  ).toEqual([])
})

// ── stale source (store-computed sourceStatus surfaced honestly) ────────────────────────────────────
test('source freshness: source_changed is a WARNING; source_missing is an ERROR (unpublishable)', () => {
  const changed = validateLocationDraft(payload(), ctx({ sourceStatus: 'source_changed' }))
  expect(codes(changed)).toEqual(['source_changed'])
  expect(severityOf(changed, 'source_changed')).toBe('warning')
  expect(changed.publishable).toBe(true)

  const missing = validateLocationDraft(payload(), ctx({ sourceStatus: 'source_missing' }))
  expect(codes(missing)).toEqual(['source_missing'])
  expect(severityOf(missing, 'source_missing')).toBe('error')
  expect(missing.publishable).toBe(false)
})

// ── conflicting drafts (local coordination WARNING) ─────────────────────────────────────────────────
test('conflicting_draft: another edit of the same live row (edit), or a same-named draft (create)', () => {
  const src = live()
  const mine = forkEdit(src, 'draft-a', 0)
  const other = forkEdit(src, 'draft-b', 0)
  const rEdit = validateLocationDraft(
    mine.payload,
    ctx({ liveLocations: [src], draftMode: mine.mode, otherDrafts: [other] }),
  )
  expect(codes(rEdit)).toEqual(['conflicting_draft'])
  expect(severityOf(rEdit, 'conflicting_draft')).toBe('warning')

  const otherCreate: LocationDraft = patch(beginCreate('draft-c', 0), { name: 'amber' }, 1)
  const rCreate = validateLocationDraft(payload({ name: 'Amber' }), ctx({ otherDrafts: [otherCreate] }))
  expect(codes(rCreate)).toEqual(['conflicting_draft'])

  // disjoint targets → no conflict
  expect(
    codes(validateLocationDraft(payload({ name: 'Amber' }), ctx({ otherDrafts: [beginCreate('d', 0)] }))),
  ).toEqual([])
})

// ── publishable semantics ───────────────────────────────────────────────────────────────────────────
test('publishable flips ONLY on error severity: warnings alone stay publishable', () => {
  // warnings only: multi-word name + duplicate + overlap + stale-changed
  const warnOnly = validateLocationDraft(
    payload({ name: 'Aurelia Port', x: 5000, y: 5000, territory_radius: 100 }),
    ctx({
      liveLocations: [live({ name: 'aurelia port', x: 5050, y: 5000, territory_radius: 100 })],
      sourceStatus: 'source_changed',
    }),
  )
  expect(warnOnly.issues.length).toBeGreaterThanOrEqual(4)
  expect(warnOnly.issues.every((i) => i.severity === 'warning')).toBe(true)
  expect(warnOnly.publishable).toBe(true)

  // add ONE error on top → unpublishable
  const withError = validateLocationDraft(
    payload({ name: 'Aurelia Port', x: 20_000, y: 5000, territory_radius: 100 }),
    ctx({
      liveLocations: [live({ name: 'aurelia port', x: 5050, y: 5000, territory_radius: 100 })],
      sourceStatus: 'source_changed',
    }),
  )
  expect(withError.issues.some((i) => i.severity === 'error')).toBe(true)
  expect(withError.publishable).toBe(false)
})

// ── enum-drift guards (single-authority law) ────────────────────────────────────────────────────────
test('locationEnums set-equals the live CHECK domains (0002_world_map.sql) and the mapTypes unions', () => {
  // Pinned expected sets — a drift in EITHER the migration mirror or mapTypes breaks this test.
  expect([...LOCATION_TYPES].sort()).toEqual(
    [
      'pirate_hunt',
      'pirate_den',
      'mining_site',
      'derelict_station',
      'trade_outpost',
      'rally_point',
      'safe_zone',
      'event_site',
    ].sort(),
  )
  expect([...ACTIVITY_TYPES].sort()).toEqual(
    ['hunt_pirates', 'mine_resource', 'explore_derelict', 'trade_visit', 'rally', 'none'].sort(),
  )
  expect([...LOCATION_STATUSES].sort()).toEqual(['active', 'locked', 'hidden'].sort())

  // Type-level: each array is pinned to the mapTypes union (compile-time direction 1); direction 2
  // (exhaustiveness) is proven by the every-member-passes loop above hitting zero issues.
  const _lt: readonly LocationType[] = LOCATION_TYPES
  const _at: readonly ActivityType[] = ACTIVITY_TYPES
  void _lt
  void _at

  // no duplicates inside the authority arrays
  expect(new Set(LOCATION_TYPES).size).toBe(LOCATION_TYPES.length)
  expect(new Set(ACTIVITY_TYPES).size).toBe(ACTIVITY_TYPES.length)
  expect(new Set(LOCATION_STATUSES).size).toBe(LOCATION_STATUSES.length)
})

test('LocationDraftPanel sources its option lists from locationEnums — no second literal copy', () => {
  const panelPath = join(
    dirname(fileURLToPath(import.meta.url)),
    '..',
    'src',
    'features',
    'worldeditor',
    'LocationDraftPanel.tsx',
  )
  const src = readFileSync(panelPath, 'utf8')
  expect(src).toContain("from './locationEnums'")
  expect(src).toContain('LOCATION_TYPES')
  expect(src).toContain('ACTIVITY_TYPES')
  // no enum literal may appear in the panel source (a literal = a drifting second copy)
  for (const literal of [...LOCATION_TYPES, ...ACTIVITY_TYPES])
    expect(src, `panel must not inline enum literal '${literal}'`).not.toContain(`'${literal}'`)
})

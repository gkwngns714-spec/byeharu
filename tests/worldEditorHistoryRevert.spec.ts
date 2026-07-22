import { test, expect } from '@playwright/test'
import {
  canRevertEntry,
  resolveLocationRevert,
  revertSeedFromEntry,
} from '../src/features/worldeditor/worldEditorHistoryRevert'
import {
  computeSourceFingerprint,
  draftPayloadFrom,
  forkEditWithPayload,
  LOCATION_DRAFT_PAYLOAD_KEYS,
} from '../src/features/worldeditor/locationDraftModel'
import type { LocationDraftPayload } from '../src/features/worldeditor/locationDraftTypes'
import type { AuditSnapshot, WorldEditorAuditEntry } from '../src/features/worldeditor/worldEditorAuditTypes'
import type { MapLocation } from '../src/features/map/mapTypes'

// WORLD EDITOR V4 — pure proofs for the "Revert to this version" slice. No browser/DB: the frontend
// spec suite runs these as deterministic Node/TS proofs. They pin (1) the button-visibility rule, (2)
// the historical-before → draft-payload projection, (3) the live-source refusal, (4) THE LOAD-BEARING
// RULE — a revert forks off the CURRENT live location (expected = current projection) with fields =
// historical — and (5) the resulting location_update command payload shape.

const T0 = 1_700_000_000_000

/** A live location as it exists NOW (the fork source — the optimistic-concurrency baseline). */
const currentLive = (over: Partial<MapLocation> = {}): MapLocation => ({
  id: 'loc-1',
  name: 'Aurelia Prime', // renamed since the historical snapshot below
  location_type: 'trade_outpost',
  x: 300, // moved since the historical snapshot
  y: -80,
  base_difficulty: 7,
  reward_tier: 4,
  activity_type: 'trade_visit',
  min_power_required: 10,
  is_public: false,
  status: 'active',
  territory_radius: 500,
  ...over,
})

/** The historical `before` values we want to restore — DELIBERATELY different from currentLive, plus
 *  the extra allow-listed snapshot keys the reader carries (id, zone_id, max_presence_seconds,
 *  created_at) that are NOT draft payload fields. */
const HISTORICAL_BEFORE: AuditSnapshot = Object.freeze({
  id: 'loc-1',
  zone_id: 'zone-9',
  name: 'Aurelia Port',
  location_type: 'safe_zone',
  activity_type: 'none',
  x: 120,
  y: -80,
  reward_tier: 3,
  base_difficulty: 5,
  min_power_required: 0,
  is_public: true,
  territory_radius: 400,
  status: 'active',
  max_presence_seconds: 600,
  created_at: '2026-01-01T00:00:00Z',
})

/** The 11-key projection of HISTORICAL_BEFORE (what the revert seed must equal). */
const HISTORICAL_PAYLOAD: LocationDraftPayload = {
  name: 'Aurelia Port',
  location_type: 'safe_zone',
  activity_type: 'none',
  x: 120,
  y: -80,
  reward_tier: 3,
  base_difficulty: 5,
  min_power_required: 0,
  is_public: true,
  territory_radius: 400,
  status: 'active',
}

const entry = (over: Partial<WorldEditorAuditEntry> = {}): WorldEditorAuditEntry => ({
  id: 'audit-1',
  requestId: 'req-1',
  commandType: 'location_update',
  targetType: 'location',
  targetId: 'loc-1',
  createdAt: '2026-02-01T00:00:00Z',
  sourceRevision: 'abcd1234',
  result: null,
  actorIsOwner: true,
  before: HISTORICAL_BEFORE,
  after: Object.freeze({ ...HISTORICAL_BEFORE, name: 'Aurelia Prime', x: 300 }),
  redactions: [],
  ...over,
})

// ── (1) button-visibility rule ─────────────────────────────────────────────────────────────────────
test('canRevertEntry is TRUE only for a location_update with a non-null before', () => {
  expect(canRevertEntry(entry())).toBe(true)
})

test('canRevertEntry is FALSE for a location_update with a null before (a create record)', () => {
  expect(canRevertEntry(entry({ before: null }))).toBe(false)
})

test('canRevertEntry is FALSE for every non-location_update command — even with a before present', () => {
  for (const commandType of [
    'location_create',
    'zone_update',
    'zone_create',
    'zone_unpublish',
    'exploration_site_update',
    'exploration_site_create',
    'exploration_site_set_active',
    'mining_field_update',
    'mining_field_create',
    'mining_field_set_active',
    'world_editor_ping',
    'some_future_unknown_command', // unknown-preserved strings are never revertable
  ]) {
    expect(canRevertEntry(entry({ commandType }))).toBe(false)
  }
})

// ── (2) historical-before → draft-payload projection ─────────────────────────────────────────────────
test('revertSeedFromEntry projects the before onto EXACTLY the 11 draft keys (extra snapshot keys dropped)', () => {
  const seed = revertSeedFromEntry(entry())
  expect(seed).toEqual(HISTORICAL_PAYLOAD)
  // no id / zone_id / max_presence_seconds / created_at leak into the seed
  expect(Object.keys(seed).sort()).toEqual([...LOCATION_DRAFT_PAYLOAD_KEYS].sort())
})

test('revertSeedFromEntry yields an empty seed for a null before', () => {
  expect(revertSeedFromEntry(entry({ before: null }))).toEqual({})
})

// ── (3) live-source resolution + refusal ─────────────────────────────────────────────────────────────
test('resolveLocationRevert resolves READY against the live location matched by targetId', () => {
  const live = currentLive()
  const res = resolveLocationRevert(entry(), [live])
  expect(res.kind).toBe('ready')
  if (res.kind !== 'ready') throw new Error('unreachable')
  expect(res.live).toBe(live) // the CURRENT live row, not the audit snapshot
  expect(res.seed).toEqual(HISTORICAL_PAYLOAD)
})

test('resolveLocationRevert refuses (source_missing) when the target is not in the live snapshot', () => {
  expect(resolveLocationRevert(entry(), []).kind).toBe('source_missing')
  expect(resolveLocationRevert(entry(), [currentLive({ id: 'other' })]).kind).toBe('source_missing')
  expect(resolveLocationRevert(entry({ targetId: null }), [currentLive()]).kind).toBe('source_missing')
})

// ── (4) THE LOAD-BEARING RULE: expected = current-live, fields = historical ───────────────────────────
test('a revert forks off the CURRENT live location: expected=current projection, fields=historical', () => {
  const live = currentLive()
  const res = resolveLocationRevert(entry(), [live])
  if (res.kind !== 'ready') throw new Error('unreachable')

  const draft = forkEditWithPayload(res.live, res.seed, 'draft-revert', T0)

  expect(draft.mode.kind).toBe('edit')
  if (draft.mode.kind !== 'edit') throw new Error('unreachable')
  // expected / optimistic-concurrency baseline = the CURRENT live projection (NOT the audit snapshot)
  expect(draft.mode.sourceId).toBe('loc-1')
  expect(draft.mode.sourceSnapshot).toEqual(draftPayloadFrom(live))
  expect(draft.mode.sourceRevision).toBe(computeSourceFingerprint(draftPayloadFrom(live)))
  // and it must NOT equal the historical projection (proves we did not fork off the snapshot)
  expect(draft.mode.sourceSnapshot).not.toEqual(HISTORICAL_PAYLOAD)
  // fields = the historical values
  expect(draft.payload).toEqual(HISTORICAL_PAYLOAD)
})

// ── (5) the resulting location_update command payload shape ───────────────────────────────────────────
test('the revert publishes as location_update with expected=current-live + fields=historical', () => {
  const live = currentLive()
  const res = resolveLocationRevert(entry(), [live])
  if (res.kind !== 'ready') throw new Error('unreachable')
  const draft = forkEditWithPayload(res.live, res.seed, 'draft-revert', T0)
  if (draft.mode.kind !== 'edit') throw new Error('unreachable')

  // exactly the payload LocationDraftPanel.onPublish builds for an edit draft
  const commandPayload = {
    target_id: draft.mode.sourceId,
    expected: draft.mode.sourceSnapshot,
    fields: draft.payload,
    source_revision: draft.mode.sourceRevision,
  }

  expect(commandPayload.target_id).toBe(live.id)
  expect(commandPayload.expected).toEqual(draftPayloadFrom(live)) // current-live, guards concurrency
  expect(commandPayload.fields).toEqual(HISTORICAL_PAYLOAD) // historical values applied
})

// ── the new primitive stays behavior-preserving for a plain (empty) seed ─────────────────────────────
test('forkEditWithPayload with an empty seed equals a plain edit fork (behavior-preserving)', () => {
  const live = currentLive()
  const draft = forkEditWithPayload(live, {}, 'draft-x', T0)
  if (draft.mode.kind !== 'edit') throw new Error('unreachable')
  expect(draft.payload).toEqual(draftPayloadFrom(live)) // no seed → payload = live projection
  expect(draft.payload).toEqual(draft.mode.sourceSnapshot)
})

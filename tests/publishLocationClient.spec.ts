import { test, expect } from '@playwright/test'
import {
  commandRpcName,
  normalizeEnvelope,
  type RawServerEnvelope,
  type WorldEditorCommandEnvelope,
} from '../src/features/worldeditor/commandContract'

// WORLD EDITOR PUBLISH SLICES (0249 + 0252) — client contract unit tests for the location command
// union members: the RPC-name mapping and envelope normalization for location_update (the THIRD
// publish domain — the location twin of the 0247/0248 update commands, uuid-addressed) and
// location_create (the LAST publishing gap — zone-scoped create; fields carry a REQUIRED zone_id).
// The SHARED vocabulary (error codes, details[] carriage, transport fallback, request-id minting)
// is already covered command-agnostically by tests/publishExplorationClient.spec.ts — not re-proven
// here. PURE: commandContract.ts performs no network IO — no live RPC is touched (the server
// behavior is proven by the disposable-matrix CI proofs,
// scripts/worldeditor-publish-location-update-proof.sql /
// scripts/worldeditor-publish-location-create-proof.sql).
// Run: `npx playwright test publishLocationClient.spec.ts`.

const UPDATE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-locupd-1',
  commandType: 'location_update',
  payload: {
    // locations are uuid-addressed (locationDraftModel liveId = live.id), unlike the name-keyed
    // exploration/mining twins.
    target_id: '3a1c2f9e-0000-4000-8000-000000000001',
    expected: {
      name: 'Haven',
      location_type: 'safe_zone',
      activity_type: 'none',
      x: 100,
      y: -200,
      reward_tier: 1,
      base_difficulty: 0,
      min_power_required: 0,
      is_public: true,
      territory_radius: null,
      status: 'active',
    },
    fields: {
      name: 'Haven Prime',
      location_type: 'rally_point',
      activity_type: 'rally',
      x: 150,
      y: -250,
      reward_tier: 2,
      base_difficulty: 1,
      min_power_required: 5,
      is_public: false,
      territory_radius: 15,
      status: 'active',
    },
    source_revision: 'abc123',
  },
}

// ── command union → RPC entrypoint map ──────────────────────────────────────────────────────────────
test('commandRpcName maps location_update to its server entrypoint', () => {
  expect(commandRpcName('location_update')).toBe('location_update')
})

// ── envelope normalization ──────────────────────────────────────────────────────────────────────────
test('normalizeEnvelope: a location update success carries {updated,id,name} + command_type through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-locupd-1',
    command_type: 'location_update',
    result: { updated: true, id: '3a1c2f9e-0000-4000-8000-000000000001', name: 'Haven Prime' },
  }
  const r = normalizeEnvelope(UPDATE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.requestId).toBe('req-locupd-1')
  expect(r.commandType).toBe('location_update')
  expect(r.result).toEqual({
    updated: true,
    id: '3a1c2f9e-0000-4000-8000-000000000001',
    name: 'Haven Prime',
  })
  expect(r.replayed).toBeUndefined()
})

test('normalizeEnvelope: a location idempotent replay keeps replayed + duplicate_request code', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: true,
    request_id: 'req-locupd-1',
    command_type: 'location_update',
    replayed: true,
    code: 'duplicate_request',
    result: { updated: true, id: '3a1c2f9e-0000-4000-8000-000000000001', name: 'Haven Prime' },
  })
  if (!r.ok) throw new Error('replay must normalize as ok')
  expect(r.replayed).toBe(true)
  expect(r.code).toBe('duplicate_request')
})

test('normalizeEnvelope: a location stale_revision envelope carries the per-field source_changed details through', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-locupd-1',
    error: 'stale_revision',
    details: [
      { code: 'source_changed', field: 'x' },
      { code: 'source_changed', field: 'territory_radius' },
    ],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('stale_revision')
  expect(r.details?.map((d) => d.field)).toEqual(['x', 'territory_radius'])
  expect(r.details?.every((d) => d.code === 'source_changed')).toBe(true)
})

test('normalizeEnvelope: a location validation_failed envelope carries the locationValidation codes through', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-locupd-1',
    error: 'validation_failed',
    details: [
      { code: 'invalid_location_type', field: 'location_type' },
      { code: 'territory_radius_not_positive', field: 'territory_radius' },
    ],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('validation_failed')
  expect(r.details?.map((d) => d.code)).toEqual([
    'invalid_location_type',
    'territory_radius_not_positive',
  ])
})

test('normalizeEnvelope: a location conflict envelope carries the duplicate_name detail through', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-locupd-1',
    error: 'conflict',
    details: [{ code: 'duplicate_name', field: 'name' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('conflict')
  expect(r.details?.[0]?.code).toBe('duplicate_name')
})

test('normalizeEnvelope: a location not_found envelope carries the source_missing detail through', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-locupd-1',
    error: 'not_found',
    details: [{ code: 'source_missing', field: null }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_found')
  expect(r.details?.[0]?.code).toBe('source_missing')
})

// ═══ location_create (0252 — the LAST publishing gap: zone-scoped CREATE) ═══════════════════════════

const CREATE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-loccre-1',
  commandType: 'location_create',
  payload: {
    // NO target_id / expected — a create has no live source row. fields carry the REQUIRED zone_id
    // (sourced client-side from the raw get_world_map tree — WorldEditorData.zoneRefs) beside the
    // 11 location draft fields.
    fields: {
      zone_id: '9b7e1c2d-0000-4000-8000-000000000042',
      name: 'New Haven',
      location_type: 'safe_zone',
      activity_type: 'none',
      x: 100,
      y: -200,
      reward_tier: 0,
      base_difficulty: 0,
      min_power_required: 0,
      is_public: true,
      territory_radius: null,
      status: 'active',
    },
  },
}

test('commandRpcName maps location_create to its server entrypoint', () => {
  expect(commandRpcName('location_create')).toBe('location_create')
})

test('normalizeEnvelope: a location create success carries {created,id,name} + command_type through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-loccre-1',
    command_type: 'location_create',
    result: { created: true, id: '5d2b0a1f-0000-4000-8000-000000000007', name: 'New Haven' },
  }
  const r = normalizeEnvelope(CREATE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.requestId).toBe('req-loccre-1')
  expect(r.commandType).toBe('location_create')
  expect(r.result).toEqual({
    created: true,
    id: '5d2b0a1f-0000-4000-8000-000000000007',
    name: 'New Haven',
  })
  expect(r.replayed).toBeUndefined()
})

test('normalizeEnvelope: a location create idempotent replay keeps replayed + duplicate_request code', () => {
  const r = normalizeEnvelope(CREATE_ENVELOPE, {
    ok: true,
    request_id: 'req-loccre-1',
    command_type: 'location_create',
    replayed: true,
    code: 'duplicate_request',
    result: { created: true, id: '5d2b0a1f-0000-4000-8000-000000000007', name: 'New Haven' },
  })
  if (!r.ok) throw new Error('replay must normalize as ok')
  expect(r.replayed).toBe(true)
  expect(r.code).toBe('duplicate_request')
})

test('normalizeEnvelope: a create validation_failed envelope carries the invalid_zone detail through', () => {
  const r = normalizeEnvelope(CREATE_ENVELOPE, {
    ok: false,
    request_id: 'req-loccre-1',
    error: 'validation_failed',
    details: [
      { code: 'invalid_zone', field: 'zone_id' },
      { code: 'name_required', field: 'name' },
    ],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('validation_failed')
  expect(r.details?.map((d) => d.code)).toEqual(['invalid_zone', 'name_required'])
  expect(r.details?.[0]?.field).toBe('zone_id')
})

test('normalizeEnvelope: a create conflict envelope carries the duplicate_name detail through', () => {
  const r = normalizeEnvelope(CREATE_ENVELOPE, {
    ok: false,
    request_id: 'req-loccre-1',
    error: 'conflict',
    details: [{ code: 'duplicate_name', field: 'name' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('conflict')
  expect(r.details?.[0]?.code).toBe('duplicate_name')
})

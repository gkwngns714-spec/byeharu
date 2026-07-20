import { test, expect } from '@playwright/test'
import {
  commandRpcName,
  describeWorldEditorError,
  newRequestId,
  normalizeEnvelope,
  type RawServerEnvelope,
  type WorldEditorCommandEnvelope,
  type WorldEditorErrorCode,
} from '../src/features/worldeditor/commandContract'

// WORLD EDITOR PUBLISH SLICES (0244 + 0247) — client contract unit tests: the
// exploration_site_create and exploration_site_update command union members, the extended error
// vocabulary (validation_failed / stale_revision / not_found / conflict), and details[]-carrying
// envelope normalization. PURE: commandContract.ts performs no network IO — no live RPC is touched
// here (the server behavior is proven by the disposable-matrix CI proofs,
// scripts/worldeditor-publish-exploration-proof.sql and
// scripts/worldeditor-publish-exploration-update-proof.sql).
// Run: `npx playwright test publishExplorationClient.spec.ts`.

const ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-1',
  commandType: 'exploration_site_create',
  payload: { fields: { name: 'X' } },
}

// ── command union → RPC entrypoint map ──────────────────────────────────────────────────────────────
test('commandRpcName maps every command kind to its server entrypoint', () => {
  expect(commandRpcName('world_editor_ping')).toBe('world_editor_ping')
  expect(commandRpcName('exploration_site_create')).toBe('exploration_site_create')
  expect(commandRpcName('exploration_site_update')).toBe('exploration_site_update')
  expect(commandRpcName('exploration_site_set_active')).toBe('exploration_site_set_active')
})

// ── extended error vocabulary ───────────────────────────────────────────────────────────────────────
test('describeWorldEditorError covers the 0244/0247 codes with distinct, non-empty copy', () => {
  const codes: WorldEditorErrorCode[] = [
    'not_authenticated',
    'not_authorized',
    'invalid_request',
    'duplicate_request',
    'validation_failed',
    'stale_revision',
    'not_found',
    'conflict',
    'transport_error',
  ]
  const messages = codes.map((c) => describeWorldEditorError(c))
  for (const m of messages) expect(m.length).toBeGreaterThan(0)
  expect(new Set(messages).size).toBe(codes.length)
})

// ── envelope normalization ──────────────────────────────────────────────────────────────────────────
test('normalizeEnvelope: a success envelope carries result/commandType through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-1',
    command_type: 'exploration_site_create',
    result: { created: true, id: 'abc', name: 'X' },
  }
  const r = normalizeEnvelope(ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.requestId).toBe('req-1')
  expect(r.commandType).toBe('exploration_site_create')
  expect(r.result).toEqual({ created: true, id: 'abc', name: 'X' })
  expect(r.replayed).toBeUndefined()
})

test('normalizeEnvelope: an idempotent replay keeps replayed + duplicate_request code', () => {
  const r = normalizeEnvelope(ENVELOPE, {
    ok: true,
    request_id: 'req-1',
    command_type: 'exploration_site_create',
    replayed: true,
    code: 'duplicate_request',
    result: { created: true, id: 'abc', name: 'X' },
  })
  if (!r.ok) throw new Error('replay must normalize as ok')
  expect(r.replayed).toBe(true)
  expect(r.code).toBe('duplicate_request')
})

test('normalizeEnvelope: a validation_failed envelope carries the structured details[] through', () => {
  const raw: RawServerEnvelope = {
    ok: false,
    request_id: 'req-1',
    error: 'validation_failed',
    details: [
      { code: 'name_required', field: 'name', message: 'Name is required.' },
      { code: 'coord_out_of_bounds', field: 'space_x', message: 'space_x must be within ±10000.' },
    ],
  }
  const r = normalizeEnvelope(ENVELOPE, raw)
  expect(r.ok).toBe(false)
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('validation_failed')
  expect(r.details).toHaveLength(2)
  expect(r.details?.[0]).toEqual({ code: 'name_required', field: 'name', message: 'Name is required.' })
})

test('normalizeEnvelope: a conflict envelope carries the duplicate_name detail through', () => {
  const r = normalizeEnvelope(ENVELOPE, {
    ok: false,
    request_id: 'req-1',
    error: 'conflict',
    details: [{ code: 'duplicate_name', field: 'name' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('conflict')
  expect(r.details?.[0]?.code).toBe('duplicate_name')
})

test('normalizeEnvelope: a failure without details stays details-less (no fabricated array)', () => {
  const r = normalizeEnvelope(ENVELOPE, { ok: false, request_id: 'req-1', error: 'not_authorized' })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_authorized')
  expect(r.details).toBeUndefined()
})

test('normalizeEnvelope: a null/shapeless server response is a typed transport_error', () => {
  const r1 = normalizeEnvelope(ENVELOPE, null)
  const r2 = normalizeEnvelope(ENVELOPE, {} as RawServerEnvelope)
  for (const r of [r1, r2]) {
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error('unreachable')
    expect(r.error).toBe('transport_error')
    expect(r.requestId).toBe('req-1')
  }
})

// ── the 0247 UPDATE command envelope ────────────────────────────────────────────────────────────────
const UPDATE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-upd-1',
  commandType: 'exploration_site_update',
  payload: {
    target_id: 'Site A',
    expected: { name: 'Site A', space_x: 1, space_y: 2, reward_bundle_json: null },
    fields: { name: 'Site B', space_x: 3, space_y: 4, reward_bundle_json: null },
    source_revision: 'abc123',
  },
}

test('normalizeEnvelope: an update success carries {updated,id,name} + command_type through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-upd-1',
    command_type: 'exploration_site_update',
    result: { updated: true, id: 'abc', name: 'Site B' },
  }
  const r = normalizeEnvelope(UPDATE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.commandType).toBe('exploration_site_update')
  expect(r.result).toEqual({ updated: true, id: 'abc', name: 'Site B' })
})

test('normalizeEnvelope: a stale_revision envelope carries the per-field source_changed details through', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-upd-1',
    error: 'stale_revision',
    details: [{ code: 'source_changed', field: 'space_x' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('stale_revision')
  expect(r.details?.[0]).toEqual({ code: 'source_changed', field: 'space_x' })
})

test('normalizeEnvelope: a not_found envelope carries the source_missing detail through', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-upd-1',
    error: 'not_found',
    details: [{ code: 'source_missing', field: null }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_found')
  expect(r.details?.[0]?.code).toBe('source_missing')
})

// ── the 0250 SET-ACTIVE (unpublish/restore) command envelope ────────────────────────────────────────
const SET_ACTIVE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-act-1',
  commandType: 'exploration_site_set_active',
  payload: {
    target_id: 'Site A',
    expected: { name: 'Site A', space_x: 1, space_y: 2, reward_bundle_json: null },
    is_active: false,
  },
}

test('normalizeEnvelope: a set_active success carries {set_active,id,name,is_active} + command_type through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-act-1',
    command_type: 'exploration_site_set_active',
    result: { set_active: true, id: 'abc', name: 'Site A', is_active: false },
  }
  const r = normalizeEnvelope(SET_ACTIVE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.commandType).toBe('exploration_site_set_active')
  expect(r.result).toEqual({ set_active: true, id: 'abc', name: 'Site A', is_active: false })
})

test('normalizeEnvelope: a set_active stale_revision envelope carries the per-field source_changed details through', () => {
  const r = normalizeEnvelope(SET_ACTIVE_ENVELOPE, {
    ok: false,
    request_id: 'req-act-1',
    error: 'stale_revision',
    details: [{ code: 'source_changed', field: 'name' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('stale_revision')
  expect(r.details?.[0]).toEqual({ code: 'source_changed', field: 'name' })
})

// ── request-id minting ──────────────────────────────────────────────────────────────────────────────
test('newRequestId mints unique UUIDs (the idempotency key is fresh per publish attempt)', () => {
  const a = newRequestId()
  const b = newRequestId()
  expect(a).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
  expect(a).not.toBe(b)
})

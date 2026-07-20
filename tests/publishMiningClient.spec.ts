import { test, expect } from '@playwright/test'
import {
  commandRpcName,
  normalizeEnvelope,
  type RawServerEnvelope,
  type WorldEditorCommandEnvelope,
} from '../src/features/worldeditor/commandContract'

// WORLD EDITOR PUBLISH SLICES (0246 + 0248) — client contract unit tests for the
// mining_field_create and mining_field_update command union members: the RPC-name mapping and
// envelope normalization for the mining twins of the 0244/0247 exploration publish commands. The
// SHARED vocabulary (error codes, details[] carriage, transport fallback, request-id minting) is
// already covered command-agnostically by tests/publishExplorationClient.spec.ts — not re-proven
// here. PURE: commandContract.ts performs no network IO — no live RPC is touched (the server
// behavior is proven by the disposable-matrix CI proofs,
// scripts/worldeditor-publish-mining-proof.sql and
// scripts/worldeditor-publish-mining-update-proof.sql).
// Run: `npx playwright test publishMiningClient.spec.ts`.

const ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-m1',
  commandType: 'mining_field_create',
  payload: { fields: { name: 'X' } },
}

// ── command union → RPC entrypoint map ──────────────────────────────────────────────────────────────
test('commandRpcName maps mining_field_create to its server entrypoint', () => {
  expect(commandRpcName('mining_field_create')).toBe('mining_field_create')
})

test('commandRpcName maps mining_field_update to its server entrypoint', () => {
  expect(commandRpcName('mining_field_update')).toBe('mining_field_update')
})

test('commandRpcName maps mining_field_set_active to its server entrypoint', () => {
  expect(commandRpcName('mining_field_set_active')).toBe('mining_field_set_active')
})

// ── envelope normalization ──────────────────────────────────────────────────────────────────────────
test('normalizeEnvelope: a mining_field_create success envelope carries result/commandType through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-m1',
    command_type: 'mining_field_create',
    result: { created: true, id: 'abc', name: 'X' },
  }
  const r = normalizeEnvelope(ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.requestId).toBe('req-m1')
  expect(r.commandType).toBe('mining_field_create')
  expect(r.result).toEqual({ created: true, id: 'abc', name: 'X' })
  expect(r.replayed).toBeUndefined()
})

test('normalizeEnvelope: a mining idempotent replay keeps replayed + duplicate_request code', () => {
  const r = normalizeEnvelope(ENVELOPE, {
    ok: true,
    request_id: 'req-m1',
    command_type: 'mining_field_create',
    replayed: true,
    code: 'duplicate_request',
    result: { created: true, id: 'abc', name: 'X' },
  })
  if (!r.ok) throw new Error('replay must normalize as ok')
  expect(r.replayed).toBe(true)
  expect(r.code).toBe('duplicate_request')
})

test('normalizeEnvelope: a mining conflict envelope carries the duplicate_name detail through', () => {
  const r = normalizeEnvelope(ENVELOPE, {
    ok: false,
    request_id: 'req-m1',
    error: 'conflict',
    details: [{ code: 'duplicate_name', field: 'name' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('conflict')
  expect(r.details?.[0]?.code).toBe('duplicate_name')
})

// ── the 0248 UPDATE command envelope ────────────────────────────────────────────────────────────────
const UPDATE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-mupd-1',
  commandType: 'mining_field_update',
  payload: {
    target_id: 'Field A',
    expected: { name: 'Field A', space_x: 1, space_y: 2, reward_bundle_json: null },
    fields: { name: 'Field B', space_x: 3, space_y: 4, reward_bundle_json: null },
    source_revision: 'abc123',
  },
}

test('normalizeEnvelope: a mining update success carries {updated,id,name} + command_type through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-mupd-1',
    command_type: 'mining_field_update',
    result: { updated: true, id: 'abc', name: 'Field B' },
  }
  const r = normalizeEnvelope(UPDATE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.commandType).toBe('mining_field_update')
  expect(r.result).toEqual({ updated: true, id: 'abc', name: 'Field B' })
})

test('normalizeEnvelope: a mining stale_revision envelope carries the per-field source_changed details through', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-mupd-1',
    error: 'stale_revision',
    details: [{ code: 'source_changed', field: 'space_x' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('stale_revision')
  expect(r.details?.[0]?.code).toBe('source_changed')
  expect(r.details?.[0]?.field).toBe('space_x')
})

test('normalizeEnvelope: a mining not_found envelope carries the source_missing detail through', () => {
  const r = normalizeEnvelope(UPDATE_ENVELOPE, {
    ok: false,
    request_id: 'req-mupd-1',
    error: 'not_found',
    details: [{ code: 'source_missing', field: null }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_found')
  expect(r.details?.[0]?.code).toBe('source_missing')
})

// ── the 0250 SET-ACTIVE (unpublish/restore) command envelope ────────────────────────────────────────
const SET_ACTIVE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-mact-1',
  commandType: 'mining_field_set_active',
  payload: {
    target_id: 'Field A',
    expected: { name: 'Field A', space_x: 1, space_y: 2, reward_bundle_json: null },
    is_active: false,
  },
}

test('normalizeEnvelope: a mining set_active success carries {set_active,id,name,is_active} + command_type through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-mact-1',
    command_type: 'mining_field_set_active',
    result: { set_active: true, id: 'abc', name: 'Field A', is_active: false },
  }
  const r = normalizeEnvelope(SET_ACTIVE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.commandType).toBe('mining_field_set_active')
  expect(r.result).toEqual({ set_active: true, id: 'abc', name: 'Field A', is_active: false })
})

test('normalizeEnvelope: a mining set_active stale_revision envelope carries the per-field source_changed details through', () => {
  const r = normalizeEnvelope(SET_ACTIVE_ENVELOPE, {
    ok: false,
    request_id: 'req-mact-1',
    error: 'stale_revision',
    details: [{ code: 'source_changed', field: 'space_y' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('stale_revision')
  expect(r.details?.[0]).toEqual({ code: 'source_changed', field: 'space_y' })
})

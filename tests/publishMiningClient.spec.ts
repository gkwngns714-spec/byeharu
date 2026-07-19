import { test, expect } from '@playwright/test'
import {
  commandRpcName,
  normalizeEnvelope,
  type RawServerEnvelope,
  type WorldEditorCommandEnvelope,
} from '../src/features/worldeditor/commandContract'

// WORLD EDITOR PUBLISH SLICE 2 (0246) — client contract unit tests for the mining_field_create
// command union member: the RPC-name mapping and envelope normalization for the mining twin of the
// 0244 exploration publish. The SHARED vocabulary (error codes, details[] carriage, transport
// fallback, request-id minting) is already covered command-agnostically by
// tests/publishExplorationClient.spec.ts — not re-proven here. PURE: commandContract.ts performs no
// network IO — no live RPC is touched (the server behavior is proven by the disposable-matrix CI
// proof, scripts/worldeditor-publish-mining-proof.sql).
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

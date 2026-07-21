import { test, expect } from '@playwright/test'
import {
  commandRpcName,
  describeWorldEditorError,
  normalizeEnvelope,
  type RawServerEnvelope,
  type WorldEditorCommandEnvelope,
  type WorldEditorCommandType,
  type WorldEditorErrorCode,
} from '../src/features/worldeditor/commandContract'

// ENEMY CONTENT REGISTRY (0257) — client contract unit tests: the six net-new command union members
// (reward_profile_create/update/set_active + enemy_archetype_create/update/set_active), their
// commandRpcName identity mapping, the fail-closed 'not_enabled' error copy, and envelope
// normalization for the registry result shapes. PURE: commandContract.ts performs no network IO —
// the server behavior is proven by scripts/enemy-content-registry-proof.sql.
// Run: `npx playwright test enemyRegistryCommandContract.spec.ts`.

const REGISTRY_COMMANDS: WorldEditorCommandType[] = [
  'reward_profile_create',
  'reward_profile_update',
  'reward_profile_set_active',
  'enemy_archetype_create',
  'enemy_archetype_update',
  'enemy_archetype_set_active',
]

// ── command union → RPC entrypoint identity map ───────────────────────────────────────────────────
test('commandRpcName maps every registry command kind to the identically-named entrypoint', () => {
  for (const c of REGISTRY_COMMANDS) {
    expect(commandRpcName(c)).toBe(c)
  }
})

// ── the fail-closed not_enabled code has distinct, non-empty copy ─────────────────────────────────
test('describeWorldEditorError copies not_enabled distinctly from the rest of the vocabulary', () => {
  const codes: WorldEditorErrorCode[] = [
    'not_authenticated',
    'not_authorized',
    'invalid_request',
    'duplicate_request',
    'validation_failed',
    'stale_revision',
    'not_found',
    'conflict',
    'not_unpublishable',
    'not_enabled',
    'transport_error',
  ]
  const messages = codes.map((c) => describeWorldEditorError(c))
  for (const m of messages) expect(m.length).toBeGreaterThan(0)
  expect(new Set(messages).size).toBe(codes.length)
  expect(describeWorldEditorError('not_enabled')).toMatch(/enabled/i)
})

// ── envelope normalization: a create success carries {created,id,key} + command_type ──────────────
const CREATE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-rp-1',
  commandType: 'reward_profile_create',
  payload: { key: 'pirate_standard', display_name: 'Standard', resource_grants: {} },
}

test('normalizeEnvelope: a reward_profile create success carries {created,id,key} through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-rp-1',
    command_type: 'reward_profile_create',
    result: { created: true, id: 'uuid-1', key: 'pirate_standard' },
  }
  const r = normalizeEnvelope(CREATE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.commandType).toBe('reward_profile_create')
  expect(r.result).toEqual({ created: true, id: 'uuid-1', key: 'pirate_standard' })
})

// ── a set_active success carries {active_set,id,key,active} through ───────────────────────────────
const SET_ACTIVE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-ea-1',
  commandType: 'enemy_archetype_set_active',
  payload: { target_id: 'pirate_light', expected_revision: 1, active: false },
}

test('normalizeEnvelope: an enemy_archetype set_active success carries {active_set,active} through', () => {
  const r = normalizeEnvelope(SET_ACTIVE_ENVELOPE, {
    ok: true,
    request_id: 'req-ea-1',
    command_type: 'enemy_archetype_set_active',
    result: { active_set: true, id: 'uuid-2', key: 'pirate_light', active: false },
  })
  if (!r.ok) throw new Error('unreachable')
  expect(r.result).toEqual({ active_set: true, id: 'uuid-2', key: 'pirate_light', active: false })
})

// ── the fail-closed not_enabled envelope normalizes as a typed failure (no fabricated details) ────
test('normalizeEnvelope: a not_enabled envelope is a typed failure with no details', () => {
  const r = normalizeEnvelope(CREATE_ENVELOPE, {
    ok: false,
    request_id: 'req-rp-1',
    error: 'not_enabled',
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_enabled')
  expect(r.details).toBeUndefined()
})

// ── a stale_revision envelope carries the per-field source_changed detail (revision) through ──────
test('normalizeEnvelope: a registry stale_revision envelope carries source_changed/revision through', () => {
  const r = normalizeEnvelope(
    { requestId: 'req-rp-2', commandType: 'reward_profile_update' },
    {
      ok: false,
      request_id: 'req-rp-2',
      error: 'stale_revision',
      details: [{ code: 'source_changed', field: 'revision' }],
    },
  )
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('stale_revision')
  expect(r.details?.[0]).toEqual({ code: 'source_changed', field: 'revision' })
})

// ── a validation_failed envelope carries the invalid_reference details through ────────────────────
test('normalizeEnvelope: an enemy_archetype validation_failed carries the reference-check details', () => {
  const r = normalizeEnvelope(
    { requestId: 'req-ea-2', commandType: 'enemy_archetype_create' },
    {
      ok: false,
      request_id: 'req-ea-2',
      error: 'validation_failed',
      details: [
        { code: 'invalid_unit_type', field: 'unit_type_id' },
        { code: 'invalid_reward_profile', field: 'default_reward_profile_id' },
      ],
    },
  )
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('validation_failed')
  expect(r.details?.map((d) => d.code)).toEqual(['invalid_unit_type', 'invalid_reward_profile'])
})

// ── a conflict (duplicate_key) envelope carries its detail through ────────────────────────────────
test('normalizeEnvelope: a registry conflict carries the duplicate_key detail through', () => {
  const r = normalizeEnvelope(CREATE_ENVELOPE, {
    ok: false,
    request_id: 'req-rp-1',
    error: 'conflict',
    details: [{ code: 'duplicate_key', field: 'key' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('conflict')
  expect(r.details?.[0]?.code).toBe('duplicate_key')
})

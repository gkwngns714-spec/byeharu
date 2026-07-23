import { test, expect } from '@playwright/test'
import {
  commandRpcName,
  normalizeEnvelope,
  type RawServerEnvelope,
  type WorldEditorCommandEnvelope,
  type WorldEditorCommandType,
} from '../src/features/worldeditor/commandContract'

// LOCATION → ENCOUNTER BINDINGS (0259) — client contract unit tests: the three net-new command union
// members (location_encounter_binding_create/update/set_active), their commandRpcName identity mapping,
// the fail-closed 'not_enabled' (tri-flag) result, success normalization, optimistic-concurrency
// stale_revision, the new per-binding validation detail codes, and the conflict duplicate_binding. PURE:
// commandContract.ts performs no network IO — server behavior is proven by
// scripts/location-encounter-bindings-proof.sql.
// Run: `npx playwright test locationEncounterBindingCommandContract.spec.ts`.

const BINDING_COMMANDS: WorldEditorCommandType[] = [
  'location_encounter_binding_create',
  'location_encounter_binding_update',
  'location_encounter_binding_set_active',
]

// ── command union → RPC entrypoint identity map ───────────────────────────────────────────────────
test('commandRpcName maps every binding command kind to the identically-named entrypoint', () => {
  for (const c of BINDING_COMMANDS) {
    expect(commandRpcName(c)).toBe(c)
  }
})

// ── a create success carries {created,id,location_id,encounter_profile_id} + command_type through ──
const CREATE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-leb-1',
  commandType: 'location_encounter_binding_create',
  payload: {
    location_id: 'loc-uuid-a',
    encounter_profile_id: 'ep-uuid-a',
    weight: 1,
  },
}

test('normalizeEnvelope: a binding create success carries {created,id,location_id,encounter_profile_id}', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-leb-1',
    command_type: 'location_encounter_binding_create',
    result: { created: true, id: 'b-uuid-1', location_id: 'loc-uuid-a', encounter_profile_id: 'ep-uuid-a' },
  }
  const r = normalizeEnvelope(CREATE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.commandType).toBe('location_encounter_binding_create')
  expect(r.result).toEqual({
    created: true,
    id: 'b-uuid-1',
    location_id: 'loc-uuid-a',
    encounter_profile_id: 'ep-uuid-a',
  })
})

// ── a set_active success carries {active_set,active} through ────────────────────────────────────────
test('normalizeEnvelope: a binding set_active success carries {active_set,active} through', () => {
  const r = normalizeEnvelope(
    { requestId: 'req-leb-2', commandType: 'location_encounter_binding_set_active' },
    {
      ok: true,
      request_id: 'req-leb-2',
      command_type: 'location_encounter_binding_set_active',
      result: { active_set: true, id: 'b-uuid-1', active: false },
    },
  )
  if (!r.ok) throw new Error('unreachable')
  expect(r.result).toEqual({ active_set: true, id: 'b-uuid-1', active: false })
})

// ── the fail-closed (tri-flag) not_enabled envelope normalizes as a typed failure, no details ──────
test('normalizeEnvelope: a binding not_enabled envelope is a typed failure with no details', () => {
  const r = normalizeEnvelope(CREATE_ENVELOPE, {
    ok: false,
    request_id: 'req-leb-1',
    error: 'not_enabled',
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_enabled')
  expect(r.details).toBeUndefined()
})

// ── a stale_revision envelope carries source_changed/revision through (optimistic concurrency) ─────
test('normalizeEnvelope: a binding stale_revision carries source_changed/revision through', () => {
  const r = normalizeEnvelope(
    { requestId: 'req-leb-3', commandType: 'location_encounter_binding_update' },
    {
      ok: false,
      request_id: 'req-leb-3',
      error: 'stale_revision',
      details: [{ code: 'source_changed', field: 'revision' }],
    },
  )
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('stale_revision')
  expect(r.details?.[0]).toEqual({ code: 'source_changed', field: 'revision' })
})

// ── a validation_failed envelope carries the NEW per-binding detail codes through ──────────────────
test('normalizeEnvelope: a binding validation_failed carries the reference/weight detail codes', () => {
  const r = normalizeEnvelope(
    { requestId: 'req-leb-4', commandType: 'location_encounter_binding_create' },
    {
      ok: false,
      request_id: 'req-leb-4',
      error: 'validation_failed',
      details: [
        { code: 'invalid_location', field: 'location_id' },
        { code: 'invalid_encounter_ref', field: 'encounter_profile_id' },
        { code: 'encounter_inactive', field: 'encounter_profile_id' },
        { code: 'invalid_weight', field: 'weight' },
      ],
    },
  )
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('validation_failed')
  expect(r.details?.map((d) => d.code)).toEqual([
    'invalid_location',
    'invalid_encounter_ref',
    'encounter_inactive',
    'invalid_weight',
  ])
})

// ── a conflict (duplicate_binding) envelope carries its detail through ─────────────────────────────
test('normalizeEnvelope: a binding conflict carries the duplicate_binding detail through', () => {
  const r = normalizeEnvelope(CREATE_ENVELOPE, {
    ok: false,
    request_id: 'req-leb-1',
    error: 'conflict',
    details: [{ code: 'duplicate_binding', field: 'encounter_profile_id' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('conflict')
  expect(r.details?.[0]?.code).toBe('duplicate_binding')
})

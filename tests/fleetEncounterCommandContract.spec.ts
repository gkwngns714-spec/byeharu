import { test, expect } from '@playwright/test'
import {
  commandRpcName,
  normalizeEnvelope,
  type RawServerEnvelope,
  type WorldEditorCommandEnvelope,
  type WorldEditorCommandType,
} from '../src/features/worldeditor/commandContract'

// FLEET TEMPLATES + ENCOUNTER PROFILES (0258) — client contract unit tests: the six net-new command
// union members (enemy_fleet_template_create/update/set_active + encounter_profile_create/update/
// set_active), their commandRpcName identity mapping, the fail-closed 'not_enabled' (dual-flag) result,
// success normalization, optimistic-concurrency stale_revision, the new per-member validation detail
// codes, and the conflict duplicate_key. PURE: commandContract.ts performs no network IO — the server
// behavior is proven by scripts/fleet-encounter-profiles-proof.sql.
// Run: `npx playwright test fleetEncounterCommandContract.spec.ts`.

const FLEET_ENCOUNTER_COMMANDS: WorldEditorCommandType[] = [
  'enemy_fleet_template_create',
  'enemy_fleet_template_update',
  'enemy_fleet_template_set_active',
  'encounter_profile_create',
  'encounter_profile_update',
  'encounter_profile_set_active',
]

// ── command union → RPC entrypoint identity map ───────────────────────────────────────────────────
test('commandRpcName maps every fleet/encounter command kind to the identically-named entrypoint', () => {
  for (const c of FLEET_ENCOUNTER_COMMANDS) {
    expect(commandRpcName(c)).toBe(c)
  }
})

// ── a fleet_template create success carries {created,id,key} + command_type through ────────────────
const FLEET_CREATE_ENVELOPE: WorldEditorCommandEnvelope = {
  requestId: 'req-ft-1',
  commandType: 'enemy_fleet_template_create',
  payload: {
    key: 'pirate_light_solo',
    display_name: 'Solo Light Pirate',
    members: [{ enemy_archetype_id: 'uuid-a', min_count: 1, max_count: 1 }],
  },
}

test('normalizeEnvelope: a fleet_template create success carries {created,id,key} through', () => {
  const raw: RawServerEnvelope = {
    ok: true,
    request_id: 'req-ft-1',
    command_type: 'enemy_fleet_template_create',
    result: { created: true, id: 'uuid-1', key: 'pirate_light_solo' },
  }
  const r = normalizeEnvelope(FLEET_CREATE_ENVELOPE, raw)
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.commandType).toBe('enemy_fleet_template_create')
  expect(r.result).toEqual({ created: true, id: 'uuid-1', key: 'pirate_light_solo' })
})

// ── an encounter set_active success carries {active_set,active} through ─────────────────────────────
test('normalizeEnvelope: an encounter_profile set_active success carries {active_set,active} through', () => {
  const r = normalizeEnvelope(
    { requestId: 'req-ep-1', commandType: 'encounter_profile_set_active' },
    {
      ok: true,
      request_id: 'req-ep-1',
      command_type: 'encounter_profile_set_active',
      result: { active_set: true, id: 'uuid-2', key: 'pirate_basic', active: false },
    },
  )
  if (!r.ok) throw new Error('unreachable')
  expect(r.result).toEqual({ active_set: true, id: 'uuid-2', key: 'pirate_basic', active: false })
})

// ── the fail-closed (dual-flag) not_enabled envelope normalizes as a typed failure, no details ─────
test('normalizeEnvelope: a fleet/encounter not_enabled envelope is a typed failure with no details', () => {
  const r = normalizeEnvelope(FLEET_CREATE_ENVELOPE, {
    ok: false,
    request_id: 'req-ft-1',
    error: 'not_enabled',
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_enabled')
  expect(r.details).toBeUndefined()
})

// ── a stale_revision envelope carries source_changed/revision through (optimistic concurrency) ─────
test('normalizeEnvelope: a fleet_template stale_revision carries source_changed/revision through', () => {
  const r = normalizeEnvelope(
    { requestId: 'req-ft-2', commandType: 'enemy_fleet_template_update' },
    {
      ok: false,
      request_id: 'req-ft-2',
      error: 'stale_revision',
      details: [{ code: 'source_changed', field: 'revision' }],
    },
  )
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('stale_revision')
  expect(r.details?.[0]).toEqual({ code: 'source_changed', field: 'revision' })
})

// ── a validation_failed envelope carries the NEW per-member detail codes through ───────────────────
test('normalizeEnvelope: a fleet_template validation_failed carries the reference/member detail codes', () => {
  const r = normalizeEnvelope(
    { requestId: 'req-ft-3', commandType: 'enemy_fleet_template_create' },
    {
      ok: false,
      request_id: 'req-ft-3',
      error: 'validation_failed',
      details: [
        { code: 'invalid_archetype_ref', field: 'enemy_archetype_id' },
        { code: 'archetype_inactive', field: 'enemy_archetype_id' },
        { code: 'invalid_count_range', field: 'members' },
        { code: 'duplicate_member', field: 'members' },
      ],
    },
  )
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('validation_failed')
  expect(r.details?.map((d) => d.code)).toEqual([
    'invalid_archetype_ref',
    'archetype_inactive',
    'invalid_count_range',
    'duplicate_member',
  ])
})

// ── an encounter validation_failed carries the encounter-specific detail codes through ─────────────
test('normalizeEnvelope: an encounter_profile validation_failed carries fleet/reward/scalar detail codes', () => {
  const r = normalizeEnvelope(
    { requestId: 'req-ep-2', commandType: 'encounter_profile_create' },
    {
      ok: false,
      request_id: 'req-ep-2',
      error: 'validation_failed',
      details: [
        { code: 'invalid_fleet_ref', field: 'fleet_template_id' },
        { code: 'fleet_inactive', field: 'fleet_template_id' },
        { code: 'invalid_reward_override', field: 'reward_override_id' },
        { code: 'invalid_difficulty', field: 'difficulty' },
        { code: 'invalid_encounter_cap', field: 'active_encounter_cap' },
        { code: 'invalid_cooldown', field: 'cooldown_seconds' },
      ],
    },
  )
  if (r.ok) throw new Error('unreachable')
  expect(r.details?.map((d) => d.code)).toEqual([
    'invalid_fleet_ref',
    'fleet_inactive',
    'invalid_reward_override',
    'invalid_difficulty',
    'invalid_encounter_cap',
    'invalid_cooldown',
  ])
})

// ── a conflict (duplicate_key) envelope carries its detail through ────────────────────────────────
test('normalizeEnvelope: a fleet/encounter conflict carries the duplicate_key detail through', () => {
  const r = normalizeEnvelope(FLEET_CREATE_ENVELOPE, {
    ok: false,
    request_id: 'req-ft-1',
    error: 'conflict',
    details: [{ code: 'duplicate_key', field: 'key' }],
  })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('conflict')
  expect(r.details?.[0]?.code).toBe('duplicate_key')
})
